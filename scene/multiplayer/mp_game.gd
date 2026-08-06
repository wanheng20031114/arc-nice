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
const LINGLAN_SKILL1_RING_MAX_PROJECTILES_PER_PACKET := (
	MpProjectileCoordinatorScript.LINGLAN_SKILL1_RING_MAX_PROJECTILES_PER_PACKET
)
const CombatTargetIndexScript := preload("res://scene/combat_target_index.gd")
const MultiplayerRuntimeMetricsScript := preload(
	"res://scene/multiplayer/multiplayer_runtime_metrics.gd"
)
const TRANSACTION_RPC_METHODS := {
	&"net_inventory_snapshot": true,
	&"net_inventory_item_used": true,
	&"net_inventory_item_discarded": true,
	&"net_simple_crafting_result": true,
	&"net_pickup_collected": true,
	&"net_upgrade_confirmed": true,
	&"net_skill1_purchase_confirmed": true,
	&"net_luoxi_collectible_confirmed": true,
	&"net_luoxi_collectible_offer_state": true,
	&"net_luoxi_collectible_refresh_confirmed": true,
	&"net_luoxi_special_game_started": true,
	&"net_luoxi_special_game_card_revealed": true,
	&"net_luoxi_special_game_finished": true,
	&"net_warehouse_command_result": true,
	&"net_warehouse_storage_snapshot_batch": true,
	&"net_production_command_result": true,
	&"net_production_state_batch": true,
	&"net_research_command_result": true,
	&"net_research_state_updated": true,
	&"net_cheat_xirang_confirmed": true,
	&"net_debug_collectible_granted": true,
}
const FEEDBACK_RPC_METHODS := {
	&"net_collectible_visual_effect": true,
	&"net_collectible_follow_visual_effect": true,
	&"net_enemy_damage_feedback_batch": true,
	&"net_enemy_damage_applied": true,
	&"net_tiyi_high_noon_targets": true,
	&"net_enemy_action": true,
	&"net_enemy_target_action": true,
	&"net_enemy_lightning_chain": true,
	&"net_plant_health_batch": true,
	&"net_tower_defense_wave_progress_changed": true,
}
const AGAVE_CANNONBALL_SCENE_PATH := "res://scene/plant_defense/agave_cannonball.tscn"
const BAMBOO_MORTAR_SCRIPT := preload(
	"res://scene/plant_defense/bamboo_mortar.gd"
)
const HYDRANGEA_RAIN_TOWER_SCRIPT := preload(
	"res://scene/plant_defense/hydrangea_rain_tower.gd"
)
const CORN_MACHINE_GUN_SCRIPT := preload("res://scene/plant_defense/corn_machine_gun.gd")
const TANGO_ELECTRIC_SURGE_FIELD_SCENE := preload(
	"res://scene/player/tango/tango_electric_surge_field.tscn"
)
const COLLECTIBLE_AREA_EFFECT_SCENE := preload("res://scene/collectible_area_effect.tscn")
const COLLECTIBLE_FROST_AREA_EFFECT_SCENE := preload("res://scene/collectible_frost_area_effect.tscn")
const COLLECTIBLE_LIGHTNING_EFFECT_SCENE := preload("res://scene/collectible_lightning_effect.tscn")
const COLLECTIBLE_MOON_SHIELD_VISUAL_SCENE := preload("res://scene/collectible_moon_shield_visual.tscn")
const INPUT_BUTTON_RELOAD := 2
const INPUT_BUTTON_DASH := 4
const DASH_INPUT_REDUNDANCY_PACKETS := 3
const DASH_COOLDOWN_NETWORK_TOLERANCE_SECONDS := 0.35
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
const GAME_RUNTIME_HOST_AUTHORITY := 1
const GAME_RUNTIME_CLIENT_VIEW := 2
const STATE_DISCONNECTED := 0
const STATE_IN_GAME := 5
const HOST_TIME_OFFSET_SMOOTH_WEIGHT := 0.08
const INPUT_CHANGE_EPSILON := 0.001
const PLAYER_STATE_MAX_ACCEPTED_JUMP_DISTANCE := 2048.0
const PLAYER_STATE_POSITION_TOLERANCE := 24.0
const PLAYER_STATE_MAX_VALIDATION_SECONDS := 0.25
const PLAYER_STATE_SPEED_TOLERANCE_MULTIPLIER := 1.75
const PLAYER_REVIVE_INVINCIBILITY_SECONDS := 3.0
const CHEAT_XIRANG_AMOUNT := 1000
const HIT_DEDUP_RETENTION_SECONDS := 30.0
const COLLECTIBLE_EFFECT_DEDUP_RETENTION_SECONDS := 10.0
const RECENT_EVENT_PRUNE_INTERVAL_SECONDS := 5.0
const CLIENT_PROJECTILE_SPAWN_POSITION_TOLERANCE := 224.0
const FIRE_SORCERER_FIREBALL_VOLLEY_TYPE: StringName = (
	&"fire_sorcerer_fireball_volley"
)
const FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_TYPE: StringName = (
	&"fire_sorcerer_elite_fireball_volley"
)
const FIRE_SLIME_TOUCH_TYPE: StringName = &"fire_slime_touch"
const FROST_SLIME_TOUCH_TYPE: StringName = &"frost_slime_touch"
const FROST_SORCERER_ICE_SPIKE_TYPE: StringName = &"frost_sorcerer_ice_spike"
const LIGHTNING_SORCERER_CHAIN_MIN_POINTS := 2
const LIGHTNING_SORCERER_CHAIN_MAX_POINTS := 6
const TIYI_SNIPER_PROJECTILE_TYPE: StringName = &"tiyi_sniper_bullet"
const TANGO_LASER_PROJECTILE_TYPE: StringName = &"tango_laser_bullet"
const TIYI_HIGH_NOON_MAX_TARGETS := 25
# Application payload budget. Keep room for Godot RPC, ENet, UDP/IP headers before MTU pressure.
const SNAPSHOT_PACKET_WARN_BYTES := 1200
const SNAPSHOT_PACKET_WARN_INTERVAL_SECONDS := 5.0
const RPC_PAYLOAD_DIAGNOSTIC_SAMPLE_INTERVAL := 64
const HOST_STARTUP_SNAPSHOT_GRACE_SECONDS := 0.5
const COMBAT_FEEDBACK_FLUSH_INTERVAL_SECONDS := 0.05
const BAMBOO_MORTAR_VISUAL_FLUSH_INTERVAL_SECONDS := 0.05
const CORN_MACHINE_GUN_BURST_FLUSH_INTERVAL_SECONDS := 0.05
const PLANT_HEALTH_FLUSH_INTERVAL_SECONDS := 0.05
# Plant records carry 41 raw packed bytes before RPC/ENet framing. Twenty-four
# records stay near 984 bytes and below the project's 1200-byte packet budget.
const PLANT_HEALTH_MAX_RECORDS_PER_PACKET := 24
const BAMBOO_MORTAR_VISUAL_MAX_RECORDS_PER_PACKET := 24
const CORN_MACHINE_GUN_BURST_MAX_RECORDS_PER_PACKET := 32
const ENEMY_TERMINAL_DEFEATED := 0
const ENEMY_TERMINAL_ESCAPED := 1
const ENEMY_TERMINAL_REMOVED := 2
const MULTIPLAYER_TEAM_PLANT_LIMIT := 256
const CLIENT_PENDING_PLANT_HEALTH_MAX_ENTRIES := MULTIPLAYER_TEAM_PLANT_LIMIT
const CLIENT_REMOVED_PLANT_TOMBSTONE_MAX_ENTRIES := MULTIPLAYER_TEAM_PLANT_LIMIT * 2
const PLANT_PLACEMENT_RATE_PER_SECOND := 4.0
const PLANT_PLACEMENT_RATE_BURST := 8.0
const PLAYER_ACTION_INGRESS_RATE_PER_SECOND := 24.0
const PLAYER_ACTION_INGRESS_RATE_BURST := 32.0
const LUOXI_TRANSACTION_RATE_PER_SECOND := 4.0
const LUOXI_TRANSACTION_RATE_BURST := 6.0
const XIAOCONG_TRANSACTION_RATE_PER_SECOND := 6.0
const XIAOCONG_TRANSACTION_RATE_BURST := 10.0
const PLANT_ID_WIRE_MAX_LENGTH := 128
const INVENTORY_ITEM_CONFIG_PATH_WIRE_MAX_LENGTH := 256
const TERRAIN_SNAPSHOT_CHUNK_MAX_CELLS := 96
const TERRAIN_SNAPSHOT_MAX_CHUNKS := 4096
const TERRAIN_DELTA_MAX_CELLS := 96
const TERRAIN_SNAPSHOT_REQUEST_RATE_PER_SECOND := 1.0
const TERRAIN_SNAPSHOT_REQUEST_RATE_BURST := 2.0
const TERRAIN_SNAPSHOT_REPAIR_WATCHDOG_SECONDS := 2.0
const TERRAIN_TYPE_EMPTY := -1
const TERRAIN_TYPE_GRASS := 1
const TERRAIN_TYPE_DIRT := 2
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
@onready var public_room_keepalive_request: HTTPRequest = $PublicRoomKeepaliveRequest

var _agave_cannonball_scene: PackedScene = null
var game: CombatRuntimeBase = null
var _gameplay_gateway: MultiplayerGameplayGateway = null
var _mode_adapter: MultiplayerModeAdapter = null
var tower_mode_adapter: TowerDefenseMultiplayerModeAdapter = null
var _linglan_boss_runtime_port: LinglanBossRuntimePort = null
var input_sequence: int = 0
var _net_time_origin: float = 0.0
var _has_host_time_offset: bool = false
var _host_to_client_time_offset: float = 0.0
var _has_sent_input: bool = false
var _last_sent_move_input: Vector2 = Vector2.ZERO
var _last_sent_shoot_input: Vector2 = Vector2.ZERO
var _input_frames_since_last_send: int = _NetConstants.INPUT_KEEPALIVE_INTERVAL_FRAMES
var _client_shoot_input_was_passive_tango_aim := false
var _local_dash_request_sequence: int = 0
var _pending_dash_request_sequence: int = 0
var _pending_dash_direction: Vector2 = Vector2.ZERO
var _pending_dash_start_move_input: Vector2 = Vector2.ZERO
var _pending_dash_input_packets: int = 0
var _local_tiyi_activation_request_id: int = 0
var _local_hoe_action_request_id: int = 0
var _local_tango_charge_request_id: int = 0
var _local_tango_active_request_id: int = 0
var _local_tango_release_pending: bool = false
var _local_tango_electric_surge_request_id: int = 0
var _last_player_state_sequences: Dictionary = {}
var _last_dash_request_sequences: Dictionary = {}
var _last_dash_confirmed_sequences: Dictionary = {}
var _last_dash_accepted_times: Dictionary = {}
var _hoe_action_sequences_by_peer: Dictionary = {}
var _last_hoe_action_request_ids: Dictionary = {}
var _tango_charge_sequences_by_peer: Dictionary = {}
var _last_tango_volley_visual_state_by_peer: Dictionary = {}
var _last_tango_charge_request_ids: Dictionary = {}
var _active_tango_charges_by_peer: Dictionary = {}
var _tango_electric_surge_sequences_by_peer: Dictionary = {}
var _last_tango_electric_surge_request_ids: Dictionary = {}
var _active_tango_electric_surges_by_peer: Dictionary = {}
var _last_tango_electric_surge_seen_by_peer: Dictionary = {}
var _tiyi_activation_sequences_by_peer: Dictionary = {}
var _active_tiyi_activations_by_peer: Dictionary = {}
var _tiyi_target_ids_by_peer: Dictionary = {}
var _pending_tiyi_target_updates: Dictionary = {}
var _last_tiyi_activation_seen_by_peer: Dictionary = {}
var _accepted_player_state_positions: Dictionary = {}
var _accepted_player_state_times: Dictionary = {}
var _processed_player_hit_ids: Dictionary = {}
var _next_collectible_effect_event_id: int = 1
var _processed_collectible_effect_event_ids: Dictionary = {}
# Highest reliable life-event revision processed per player. On Host this is
# also the allocator; on clients it deduplicates presentation events.
var _player_health_revisions: Dictionary = {}
var _disconnected_player_reconnect_states: Dictionary[int, Dictionary] = {}
var _dead_player_revive_times: Dictionary = {}
var _dead_player_revive_last_seconds: Dictionary = {}
var _recent_event_prune_time_left: float = RECENT_EVENT_PRUNE_INTERVAL_SECONDS
var _snapshot_packet_warn_time_left: float = 0.0
var _host_startup_snapshot_grace_time_left: float = 0.0
var _client_host_game_ready: bool = false
var _max_player_snapshot_packet_bytes: int = 0
var _max_enemy_snapshot_packet_bytes: int = 0
var _large_player_snapshot_packet_count: int = 0
var _large_enemy_snapshot_packet_count: int = 0
var _enemy_snapshot_payload_bytes_total: int = 0
var _enemy_snapshot_packet_count: int = 0
var _last_plant_placement_request_ids: Dictionary = {}
var _plant_placement_rate_buckets: Dictionary = {}
var _player_action_ingress_rate_buckets: Dictionary = {}
var _luoxi_transaction_rate_buckets: Dictionary = {}
var _xiaocong_transaction_rate_buckets: Dictionary = {}
var _terrain_snapshot_request_rate_buckets: Dictionary = {}
var _luoxi_offer_states_by_peer: Dictionary = {}
var _luoxi_offer_revision_counters: Dictionary = {}
var _combat_feedback_flush_time_left: float = COMBAT_FEEDBACK_FLUSH_INTERVAL_SECONDS
var _pending_bamboo_mortar_visuals := PackedInt32Array()
var _pending_bamboo_mortar_action_ids := PackedInt32Array()
var _pending_bamboo_mortar_stages := PackedByteArray()
var _pending_bamboo_mortar_spawn_positions := PackedVector2Array()
var _pending_bamboo_mortar_landing_positions := PackedVector2Array()
var _pending_bamboo_mortar_windup_durations := PackedFloat32Array()
var _pending_bamboo_mortar_host_times := PackedFloat64Array()
var _bamboo_mortar_visual_flush_time_left: float = (
	BAMBOO_MORTAR_VISUAL_FLUSH_INTERVAL_SECONDS
)
var _pending_corn_machine_gun_burst_visuals := PackedInt32Array()
var _pending_corn_machine_gun_burst_action_ids := PackedInt32Array()
var _pending_corn_machine_gun_burst_directions := PackedVector2Array()
var _pending_corn_machine_gun_burst_host_times := PackedFloat64Array()
var _corn_machine_gun_burst_flush_time_left: float = (
	CORN_MACHINE_GUN_BURST_FLUSH_INTERVAL_SECONDS
)
var _pending_plant_health_updates: Dictionary = {}
var _plant_health_flush_time_left: float = PLANT_HEALTH_FLUSH_INTERVAL_SECONDS
# CH5 spawn/removal and CH7 health feedback have independent delivery order.
# Keep only bounded client-side ordering state; the Host remains authoritative.
var _pending_remote_plant_health_updates: Dictionary = {}
var _pending_remote_plant_health_order: Array[int] = []
var _removed_remote_plant_ids: Dictionary = {}
var _removed_remote_plant_id_order: Array[int] = []
var _remote_plant_feedback_revisions: Dictionary = {}
var _remote_plant_feedback_revision_order: Array[int] = []
var _public_room_keepalive_time_left: float = 0.0
var _public_room_keepalive_in_flight: bool = false
var _next_terrain_snapshot_id: int = 1
var _last_host_terrain_revision_broadcast: int = 0
var _client_terrain_revision: int = -1
var _client_has_terrain_snapshot: bool = false
var _client_waiting_for_terrain_snapshot: bool = false
var _terrain_snapshot_repair_watchdog_time_left: float = 0.0
var _last_completed_terrain_snapshot_id: int = 0
var _pending_terrain_snapshot_batches: Dictionary = {}
var _rpc_payload_diagnostics_enabled := false
var _rpc_payload_call_counts: Dictionary[StringName, int] = {}
var _rpc_payload_sample_bytes: Dictionary[StringName, int] = {}
var _rpc_payload_sample_count := 0
var _revive_random_generator := RandomNumberGenerator.new()
var _luoxi_offer_random_generator := RandomNumberGenerator.new()
var _runtime_network_metrics = MultiplayerRuntimeMetricsScript.new(
	_NetConstants.CHANNEL_COUNT
)
var _embedded_runtime_active := false
var _embedded_participant_peer_ids: Dictionary[int, bool] = {}
var _suspended_embedded_participant_peer_ids: Dictionary[int, bool] = {}


func _ready() -> void:
	_net_time_origin = Time.get_ticks_msec() / 1000.0
	_revive_random_generator.randomize()
	_luoxi_offer_random_generator.randomize()
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
	if not public_room_keepalive_request.request_completed.is_connected(_on_public_room_keepalive_completed):
		public_room_keepalive_request.request_completed.connect(_on_public_room_keepalive_completed)
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
	_gameplay_gateway = null
	_mode_adapter = null
	tower_mode_adapter = null
	_linglan_boss_runtime_port = null
	if public_room_keepalive_request != null:
		if public_room_keepalive_request.request_completed.is_connected(_on_public_room_keepalive_completed):
			public_room_keepalive_request.request_completed.disconnect(_on_public_room_keepalive_completed)
		if public_room_keepalive_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
			public_room_keepalive_request.cancel_request()
	_processed_collectible_effect_event_ids.clear()
	_clear_bamboo_mortar_visuals()
	_pending_corn_machine_gun_burst_visuals.clear()
	_pending_corn_machine_gun_burst_action_ids.clear()
	_pending_corn_machine_gun_burst_directions.clear()
	_pending_corn_machine_gun_burst_host_times.clear()
	_pending_plant_health_updates.clear()
	_clear_remote_plant_health_state()
	if tower_economy_coordinator != null:
		tower_economy_coordinator.reset_session_state()
	_pending_terrain_snapshot_batches.clear()
	_terrain_snapshot_request_rate_buckets.clear()
	_terrain_snapshot_repair_watchdog_time_left = 0.0
	_luoxi_offer_states_by_peer.clear()
	_luoxi_offer_revision_counters.clear()
	_player_action_ingress_rate_buckets.clear()
	_luoxi_transaction_rate_buckets.clear()
	_xiaocong_transaction_rate_buckets.clear()
	_public_room_keepalive_in_flight = false


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
	_update_public_room_keepalive(delta)
	if net_manager.is_client() or net_manager.is_host():
		_client_interpolate_entities()
	if net_manager.is_client() and game != null:
		_update_terrain_snapshot_repair_watchdog(delta)
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
	_runtime_network_metrics.record_transaction_latency_ms(latency_ms)


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
	if not _has_tower_mode():
		return
	if net_manager.is_host():
		tower_mode_adapter.request_xiaocong_interaction(
			_get_local_peer_id()
		)
	elif net_manager.is_client():
		net_xiaocong_interaction_requested.rpc_id(_get_host_peer_id())


func _on_local_xiaocong_vote_requested(
	option_id: StringName,
	permanent_buff_id: StringName
) -> void:
	if (
		not _has_tower_mode()
		or not _is_valid_xiaocong_vote_payload(option_id, permanent_buff_id)
	):
		return
	if net_manager.is_host():
		tower_mode_adapter.request_xiaocong_fate_vote(
			_get_local_peer_id(),
			option_id,
			permanent_buff_id
		)
	elif net_manager.is_client():
		net_xiaocong_fate_vote_requested.rpc_id(
			_get_host_peer_id(),
			String(option_id),
			String(permanent_buff_id)
		)


func _on_local_xiaocong_collectible_requested(choice_index: int) -> void:
	if (
		not _has_tower_mode()
		or choice_index < 0
		or choice_index > 3
	):
		return
	if net_manager.is_host():
		tower_mode_adapter.request_xiaocong_collectible_choice(
			_get_local_peer_id(),
			choice_index
		)
	elif net_manager.is_client():
		net_xiaocong_collectible_choice_requested.rpc_id(
			_get_host_peer_id(),
			choice_index
		)


func _is_valid_xiaocong_vote_payload(
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


func notify_local_player_dash_started(direction: Vector2, start_move_input: Vector2) -> void:
	if game == null or not _client_host_game_ready:
		return
	if not _is_finite_vector2(direction) or not _is_finite_vector2(start_move_input):
		return
	if direction.length_squared() <= 0.001 or start_move_input.length_squared() <= 0.001:
		return
	var peer_id := _get_local_peer_id()
	var player_node := game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node) or not player_node.is_dashing():
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
	if net_manager.is_host():
		_pending_dash_input_packets = 0
		_broadcast_player_dash_confirmed(
			peer_id,
			safe_direction,
			_pending_dash_request_sequence
		)
	elif net_manager.is_client():
		net_player_dash_requested.rpc_id(
			_get_host_peer_id(),
			_pending_dash_request_sequence,
			safe_direction,
			safe_start_move_input
		)


func request_hoe_primary_attack(direction: Vector2) -> bool:
	if game == null or not _client_host_game_ready:
		return false
	var peer_id := _get_local_peer_id()
	var player_node := game.get_player_for_peer(peer_id)
	if not _is_valid_hoe_cat_player(player_node):
		return false
	var safe_direction := _sanitize_hoe_action_direction(player_node, direction)
	if net_manager.is_host():
		return _apply_authoritative_hoe_action(peer_id, HOE_ACTION_PRIMARY, safe_direction)
	if not net_manager.is_client():
		return false
	_local_hoe_action_request_id += 1
	player_node.call(
		"play_predicted_hoe_action",
		HOE_ACTION_PRIMARY,
		safe_direction,
		_local_hoe_action_request_id
	)
	net_hoe_primary_attack_requested.rpc_id(
		_get_host_peer_id(),
		safe_direction,
		_local_hoe_action_request_id
	)
	return true


func request_hoe_whirlwind() -> bool:
	if game == null or not _client_host_game_ready:
		return false
	var peer_id := _get_local_peer_id()
	var player_node := game.get_player_for_peer(peer_id)
	if not _is_valid_hoe_cat_player(player_node):
		return false
	if net_manager.is_host():
		return _apply_authoritative_hoe_action(peer_id, HOE_ACTION_WHIRLWIND, Vector2.ZERO)
	if not net_manager.is_client():
		return false
	_local_hoe_action_request_id += 1
	player_node.call(
		"play_predicted_hoe_action",
		HOE_ACTION_WHIRLWIND,
		Vector2.ZERO,
		_local_hoe_action_request_id
	)
	net_hoe_whirlwind_requested.rpc_id(_get_host_peer_id(), _local_hoe_action_request_id)
	return true


func request_tango_electric_surge() -> bool:
	if game == null or not _client_host_game_ready:
		return false
	var peer_id := _get_local_peer_id()
	var player_node := game.get_player_for_peer(peer_id)
	if not _is_valid_tango_player(player_node):
		return false
	if (
		bool(player_node.call("is_electric_surge_active"))
		or _active_tango_electric_surges_by_peer.has(peer_id)
	):
		return false
	_local_tango_electric_surge_request_id += 1
	var request_id := _local_tango_electric_surge_request_id
	if net_manager.is_host():
		return _apply_authoritative_tango_electric_surge_request(
			peer_id,
			request_id
		)
	if not net_manager.is_client():
		return false
	net_tango_electric_surge_requested.rpc_id(
		_get_host_peer_id(),
		request_id
	)
	return true


func spawn_authoritative_tango_electric_surge_field(
	owner_player: Player,
	activation_id: int,
	origin: Vector2
) -> bool:
	if (
		not net_manager.is_host()
		or game == null
		or owner_player == null
		or not is_instance_valid(owner_player)
		or activation_id <= 0
		or not _is_finite_vector2(origin)
	):
		return false
	var owner_peer_id := owner_player.peer_id
	if owner_peer_id <= 0 or game.get_player_for_peer(owner_peer_id) != owner_player:
		return false
	var field := (
		TANGO_ELECTRIC_SURGE_FIELD_SCENE.instantiate()
		as TangoElectricSurgeField
	)
	if field == null:
		return false
	var gameplay_gateway := game.get_multiplayer_gameplay_gateway()
	if gameplay_gateway == null:
		field.free()
		return false
	field.bind_gameplay_context(game, gameplay_gateway)
	field.connect(
		&"finished",
		Callable(self, "_on_authoritative_tango_electric_surge_field_finished").bind(
			owner_peer_id,
			activation_id
		),
		CONNECT_ONE_SHOT
	)
	game.add_child(field)
	field.global_position = origin
	field.call(
		"setup",
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
		game == null
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
	var gameplay_gateway := game.get_multiplayer_gameplay_gateway()
	if gameplay_gateway == null:
		field.free()
		return false
	field.bind_gameplay_context(game, gameplay_gateway)
	game.add_child(field)
	field.global_position = origin
	field.setup_multiplayer_visual_only(
		activation_id,
		minf(remaining_seconds, TANGO_ELECTRIC_SURGE_DURATION_SECONDS)
	)
	return true


func _on_authoritative_tango_electric_surge_field_finished(
	_field: Node,
	owner_peer_id: int,
	activation_id: int
) -> void:
	_finish_authoritative_tango_electric_surge(owner_peer_id, activation_id)


func request_tango_charge_started(direction: Vector2) -> bool:
	if game == null or not _client_host_game_ready or _local_tango_active_request_id > 0:
		return false
	var peer_id := _get_local_peer_id()
	var player_node := game.get_player_for_peer(peer_id)
	if not _is_valid_tango_player(player_node):
		return false
	var safe_direction := _sanitize_tango_charge_direction(player_node, direction)
	_local_tango_charge_request_id += 1
	var request_id := _local_tango_charge_request_id
	if net_manager.is_host():
		var accepted := _apply_authoritative_tango_charge_started(
			peer_id,
			safe_direction,
			request_id
		)
		if accepted and bool(player_node.call("is_tango_charge_active")):
			_local_tango_active_request_id = request_id
		return accepted
	if not net_manager.is_client():
		return false
	_local_tango_active_request_id = request_id
	_local_tango_release_pending = false
	net_tango_charge_started_requested.rpc_id(
		_get_host_peer_id(),
		safe_direction,
		request_id
	)
	return true


func request_tango_charge_released(direction: Vector2) -> bool:
	if (
		game == null
		or not _client_host_game_ready
		or _local_tango_active_request_id <= 0
		or _local_tango_release_pending
	):
		return false
	var peer_id := _get_local_peer_id()
	var player_node := game.get_player_for_peer(peer_id)
	if not _is_valid_tango_player(player_node):
		return false
	var safe_direction := _sanitize_tango_charge_direction(player_node, direction)
	var request_id := _local_tango_active_request_id
	_local_tango_release_pending = true
	if net_manager.is_host():
		var handled := _apply_authoritative_tango_charge_released(
			peer_id,
			safe_direction,
			request_id
		)
		_local_tango_active_request_id = 0
		_local_tango_release_pending = false
		return handled
	if not net_manager.is_client():
		_local_tango_release_pending = false
		return false
	net_tango_charge_released_requested.rpc_id(
		_get_host_peer_id(),
		safe_direction,
		request_id
	)
	return true


func request_tango_charge_cancelled() -> bool:
	if (
		game == null
		or not _client_host_game_ready
		or _local_tango_active_request_id <= 0
		or _local_tango_release_pending
	):
		return false
	var peer_id := _get_local_peer_id()
	var player_node := game.get_player_for_peer(peer_id)
	if not _is_valid_tango_player(player_node):
		return false
	var request_id := _local_tango_active_request_id
	_local_tango_release_pending = true
	if net_manager.is_host():
		var handled := _apply_authoritative_tango_charge_cancelled(peer_id, request_id)
		if not handled:
			_local_tango_release_pending = false
		return handled
	if not net_manager.is_client():
		_local_tango_release_pending = false
		return false
	net_tango_charge_cancelled_requested.rpc_id(_get_host_peer_id(), request_id)
	return true


func request_tiyi_high_noon() -> bool:
	if game == null or not _client_host_game_ready:
		return false
	var peer_id := _get_local_peer_id()
	var player_node := game.get_player_for_peer(peer_id)
	if not _is_valid_tiyi_player(player_node):
		return false
	if (
		bool(player_node.call("is_high_noon_active"))
		or _active_tiyi_activations_by_peer.has(peer_id)
	):
		return false
	if net_manager.is_host():
		var activation_id := int(_tiyi_activation_sequences_by_peer.get(peer_id, 0)) + 1
		return _apply_authoritative_tiyi_high_noon_request(peer_id, activation_id)
	if not net_manager.is_client():
		return false
	_local_tiyi_activation_request_id += 1
	net_tiyi_high_noon_requested.rpc_id(
		_get_host_peer_id(),
		_local_tiyi_activation_request_id
	)
	return true


func notify_tiyi_high_noon_targets_changed(
	peer_id: int,
	activation_id: int,
	target_ids: PackedInt32Array
) -> void:
	if not net_manager.is_host() or game == null:
		return
	if int(_active_tiyi_activations_by_peer.get(peer_id, 0)) != activation_id:
		return
	var sanitized_target_ids := _sanitize_tiyi_target_ids(target_ids)
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
	if not net_manager.is_host() or game == null:
		return
	if int(_active_tiyi_activations_by_peer.get(peer_id, 0)) != activation_id:
		return
	var player_node := game.get_player_for_peer(peer_id)
	if not _is_valid_tiyi_player(player_node):
		_cancel_authoritative_tiyi_high_noon(peer_id, activation_id, true)
		return
	var locked_ids := _tiyi_target_ids_by_peer.get(peer_id, PackedInt32Array()) as PackedInt32Array
	var locked_lookup: Dictionary = {}
	for locked_id in locked_ids:
		locked_lookup[int(locked_id)] = true
	var resolved_ids := PackedInt32Array()
	var resolved_positions := PackedVector2Array()
	var resolved_enemies: Array[Enemy] = []
	var seen_ids: Dictionary = {}
	for target_index in range(mini(target_ids.size(), TIYI_HIGH_NOON_MAX_TARGETS)):
		var enemy_net_id := int(target_ids[target_index])
		if enemy_net_id <= 0 or seen_ids.has(enemy_net_id) or not locked_lookup.has(enemy_net_id):
			continue
		var enemy := _get_host_enemy_for_net_id(enemy_net_id)
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			continue
		seen_ids[enemy_net_id] = true
		resolved_ids.append(enemy_net_id)
		# Host gameplay state is authoritative; callback positions are only a visual hint.
		resolved_positions.append(enemy.global_position)
		resolved_enemies.append(enemy)
	_active_tiyi_activations_by_peer.erase(peer_id)
	_tiyi_target_ids_by_peer.erase(peer_id)
	_rpc_to_connected_clients(
		&"net_tiyi_high_noon_finished",
		[peer_id, activation_id, resolved_ids, resolved_positions]
	)
	for target_index in range(resolved_enemies.size()):
		var enemy := resolved_enemies[target_index]
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			continue
		var enemy_net_id := int(resolved_ids[target_index])
		var resolved_damage := int(
			player_node.call("get_high_noon_damage_against_enemy", enemy)
		)
		var impact_direction := -player_node.global_position.direction_to(enemy.global_position)
		_apply_confirmed_enemy_damage(
			enemy_net_id,
			enemy,
			resolved_damage,
			impact_direction,
			EnemyConfig.DamageType.MAGIC,
			false
		)


func cancel_tiyi_high_noon(peer_id: int, activation_id: int) -> void:
	_cancel_authoritative_tiyi_high_noon(peer_id, activation_id, true)


func uses_authoritative_luoxi_offers() -> bool:
	return true


func request_luoxi_collectible_offer() -> void:
	var peer_id := _get_local_peer_id()
	if net_manager.is_host():
		_send_or_create_luoxi_offer_for_peer(peer_id)
	elif net_manager.is_client():
		net_luoxi_collectible_offer_requested.rpc_id(_get_host_peer_id())


func request_luoxi_collectible_choice(
	choice_index: int,
	_legacy_config_path: String = "",
	offer_revision: int = 0
) -> void:
	if net_manager.is_host():
		_apply_luoxi_collectible_choice_for_peer(
			_get_local_peer_id(),
			choice_index,
			"",
			offer_revision,
			false
		)
	elif net_manager.is_client():
		net_luoxi_collectible_choice_requested.rpc_id(
			_get_host_peer_id(),
			choice_index,
			offer_revision
		)


func request_luoxi_collectible_refresh(offer_revision: int = 0) -> void:
	if net_manager.is_host():
		_apply_luoxi_collectible_refresh_for_peer(
			_get_local_peer_id(),
			offer_revision,
			false
		)
	elif net_manager.is_client():
		net_luoxi_collectible_refresh_requested.rpc_id(
			_get_host_peer_id(),
			offer_revision
		)


func request_luoxi_special_game_start() -> void:
	if net_manager.is_host():
		_apply_luoxi_special_game_start_for_peer(_get_local_peer_id())
	elif net_manager.is_client():
		net_luoxi_special_game_start_requested.rpc_id(_get_host_peer_id())


func supports_luoxi_special_game() -> bool:
	return (
		_mode_adapter != null
		and _mode_adapter.runtime_supports_luoxi_special_game()
	)


func request_luoxi_special_game_card_reveal(
	session_revision: int,
	card_index: int
) -> void:
	if net_manager.is_host():
		_apply_luoxi_special_game_card_reveal_for_peer(
			_get_local_peer_id(),
			session_revision,
			card_index
		)
	elif net_manager.is_client():
		net_luoxi_special_game_card_reveal_requested.rpc_id(
			_get_host_peer_id(),
			session_revision,
			card_index
		)


func request_luoxi_special_game_finish(session_revision: int) -> void:
	if net_manager.is_host():
		_apply_luoxi_special_game_finish_for_peer(
			_get_local_peer_id(),
			session_revision
		)
	elif net_manager.is_client():
		net_luoxi_special_game_finish_requested.rpc_id(
			_get_host_peer_id(),
			session_revision
		)


func has_luoxi_collectible_claimed(peer_id: int) -> bool:
	if _mode_adapter == null:
		return false
	return _mode_adapter.runtime_has_luoxi_collectible_claimed(peer_id)


func broadcast_collectible_visual_effect(
	effect_type: StringName,
	spawn_position: Vector2,
	radius: float,
	color: Color,
	duration: float
) -> void:
	if net_manager == null or not net_manager.is_host():
		return
	var effect_event_id := _next_collectible_effect_event_id
	_next_collectible_effect_event_id += 1
	_rpc_to_connected_clients(
		&"net_collectible_visual_effect",
		[String(effect_type), spawn_position, radius, color, duration, effect_event_id]
	)


func broadcast_collectible_follow_visual_effect(
	effect_type: StringName,
	owner_peer_id: int,
	radius: float,
	duration: float
) -> void:
	if net_manager == null or not net_manager.is_host():
		return
	if owner_peer_id <= 0:
		return
	var effect_event_id := _next_collectible_effect_event_id
	_next_collectible_effect_event_id += 1
	_rpc_to_connected_clients(
		&"net_collectible_follow_visual_effect",
		[String(effect_type), owner_peer_id, radius, duration, effect_event_id]
	)


func request_multiplayer_cheat_xirang() -> void:
	if not OS.is_debug_build():
		return
	if net_manager.is_host():
		_apply_cheat_xirang_for_peer(_get_local_peer_id())
	else:
		net_cheat_xirang_requested.rpc_id(_get_host_peer_id())


func request_debug_collectible(config_path: String) -> void:
	if (
		game == null
		or _mode_adapter == null
		or not _mode_adapter.allows_debug_collectible_grants()
	):
		return
	if net_manager.is_host():
		_apply_debug_collectible_for_peer(_get_local_peer_id(), config_path)
	else:
		net_debug_collectible_requested.rpc_id(_get_host_peer_id(), config_path)


func _on_local_plant_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i
) -> void:
	if not _has_tower_mode():
		return
	if net_manager.is_host():
		_handle_authoritative_plant_placement_request(
			_get_local_peer_id(),
			request_id,
			String(plant_id),
			anchor
		)
	elif net_manager.is_client():
		net_plant_placement_requested.rpc_id(
			_get_host_peer_id(),
			request_id,
			String(plant_id),
			anchor
		)


func _on_local_inventory_plant_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
) -> void:
	if not _has_tower_mode():
		return
	if net_manager.is_host():
		_handle_authoritative_inventory_plant_placement_request(
			_get_local_peer_id(),
			request_id,
			String(plant_id),
			anchor,
			slot_index,
			expected_inventory_revision,
			item_config_path
		)
	elif net_manager.is_client():
		net_inventory_plant_placement_requested.rpc_id(
			_get_host_peer_id(),
			request_id,
			String(plant_id),
			anchor,
			slot_index,
			expected_inventory_revision,
			item_config_path
		)


func _handle_authoritative_plant_placement_request(
	requester_peer_id: int,
	request_id: int,
	plant_id_wire: String,
	anchor: Vector2i
) -> void:
	if not net_manager.is_host() or not _has_tower_mode():
		return
	if not transactions_coordinator.consume_remote_transaction_admission(
		requester_peer_id
	):
		return
	if (
		request_id <= 0
		or plant_id_wire.is_empty()
		or plant_id_wire.length() > PLANT_ID_WIRE_MAX_LENGTH
	):
		return
	if not _consume_peer_rate_token(
		_plant_placement_rate_buckets,
		requester_peer_id,
		PLANT_PLACEMENT_RATE_PER_SECOND,
		PLANT_PLACEMENT_RATE_BURST
	):
		return
	var last_request_id := int(_last_plant_placement_request_ids.get(requester_peer_id, 0))
	if request_id <= last_request_id:
		_send_plant_placement_rejected(requester_peer_id, request_id, &"stale_request")
		return
	_last_plant_placement_request_ids[requester_peer_id] = request_id
	if _get_authoritative_team_plant_count() >= MULTIPLAYER_TEAM_PLANT_LIMIT:
		_send_plant_placement_rejected(requester_peer_id, request_id, &"team_limit_reached")
		return
	tower_mode_adapter.request_authoritative_plant_placement(
		requester_peer_id,
		request_id,
		StringName(plant_id_wire),
		anchor
	)


func _handle_authoritative_inventory_plant_placement_request(
	requester_peer_id: int,
	request_id: int,
	plant_id_wire: String,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
) -> void:
	if not net_manager.is_host() or not _has_tower_mode():
		return
	if not transactions_coordinator.consume_remote_transaction_admission(
		requester_peer_id
	):
		return
	if (
		request_id <= 0
		or plant_id_wire.is_empty()
		or plant_id_wire.length() > PLANT_ID_WIRE_MAX_LENGTH
		or slot_index < 0
		or slot_index >= RunStateStore.INVENTORY_CAPACITY
		or expected_inventory_revision < 0
		or item_config_path.is_empty()
		or item_config_path.length() > INVENTORY_ITEM_CONFIG_PATH_WIRE_MAX_LENGTH
	):
		return
	if not _consume_peer_rate_token(
		_plant_placement_rate_buckets,
		requester_peer_id,
		PLANT_PLACEMENT_RATE_PER_SECOND,
		PLANT_PLACEMENT_RATE_BURST
	):
		return
	var last_request_id := int(
		_last_plant_placement_request_ids.get(requester_peer_id, 0)
	)
	if request_id <= last_request_id:
		_send_plant_placement_rejected(
			requester_peer_id,
			request_id,
			&"stale_request"
		)
		return
	_last_plant_placement_request_ids[requester_peer_id] = request_id
	if _get_authoritative_team_plant_count() >= MULTIPLAYER_TEAM_PLANT_LIMIT:
		_send_plant_placement_rejected(
			requester_peer_id,
			request_id,
			&"team_limit_reached"
		)
		return
	tower_mode_adapter.request_authoritative_inventory_plant_placement(
		requester_peer_id,
		request_id,
		StringName(plant_id_wire),
		anchor,
		slot_index,
		expected_inventory_revision,
		item_config_path
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
	if (
		not net_manager.is_host()
		or game == null
		or peer_id <= 0
		or _is_embedded_participant_suspended(peer_id)
		or game.get_player_for_peer(peer_id) == null
	):
		return false
	return _consume_peer_rate_token(
		_player_action_ingress_rate_buckets,
		peer_id,
		PLAYER_ACTION_INGRESS_RATE_PER_SECOND,
		PLAYER_ACTION_INGRESS_RATE_BURST,
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
	if not _has_tower_mode():
		return null
	return tower_mode_adapter.get_multiplayer_plant_node(net_id)


func _get_tower_plant_snapshots() -> Array[Dictionary]:
	if not _has_tower_mode():
		return []
	return tower_mode_adapter.get_multiplayer_plant_snapshots()


func _get_authoritative_team_plant_count() -> int:
	if not _has_tower_mode():
		return 0
	var plant_count := tower_mode_adapter.get_authoritative_team_plant_count()
	if plant_count < 0:
		# A tower-defense Host without its authoritative registry must fail closed;
		# accepting placements here would silently bypass the shared team limit.
		return MULTIPLAYER_TEAM_PLANT_LIMIT
	return plant_count


func broadcast_plant_projectile_visual(
	_plant_net_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	speed: float,
	explosion_radius: float,
	lifetime: float
) -> void:
	if (
		not _has_tower_mode()
		or not net_manager.is_host()
		or not _is_finite_vector2(spawn_position)
		or not _is_finite_vector2(direction)
		or direction.length_squared() <= 0.001
	):
		return
	_rpc_to_connected_clients(
		&"net_plant_projectile_visual",
		[
			spawn_position,
			direction.normalized(),
			maxf(speed, 0.0),
			maxf(explosion_radius, 1.0),
			maxf(lifetime, 0.01),
		]
	)


func queue_bamboo_mortar_visual(
	plant_net_id: int,
	action_id: int,
	stage: int,
	spawn_position: Vector2,
	landing_position: Vector2,
	committed_windup_duration_seconds: float
) -> void:
	if (
		not _has_tower_mode()
		or not is_inside_tree()
		or not net_manager.is_host()
		or game == null
		or plant_net_id <= 0
		or action_id <= 0
		or stage < 0
		or stage > 1
		or not _is_finite_vector2(spawn_position)
		or not _is_finite_vector2(landing_position)
		or not is_finite(committed_windup_duration_seconds)
		or committed_windup_duration_seconds
			< BAMBOO_MORTAR_SCRIPT.MIN_COMMITTED_WINDUP_DURATION_SECONDS
		or committed_windup_duration_seconds
			> BAMBOO_MORTAR_SCRIPT.WINDUP_DURATION_SECONDS
	):
		return
	var mortar := _get_tower_plant(plant_net_id)
	if (
		mortar == null
		or not is_instance_valid(mortar)
		or mortar.get_script() != BAMBOO_MORTAR_SCRIPT
	):
		return
	_pending_bamboo_mortar_visuals.append(plant_net_id)
	_pending_bamboo_mortar_action_ids.append(action_id)
	_pending_bamboo_mortar_stages.append(stage)
	_pending_bamboo_mortar_spawn_positions.append(spawn_position)
	_pending_bamboo_mortar_landing_positions.append(landing_position)
	_pending_bamboo_mortar_windup_durations.append(
		committed_windup_duration_seconds
	)
	_pending_bamboo_mortar_host_times.append(_get_net_time())


func _clear_bamboo_mortar_visuals() -> void:
	_pending_bamboo_mortar_visuals.clear()
	_pending_bamboo_mortar_action_ids.clear()
	_pending_bamboo_mortar_stages.clear()
	_pending_bamboo_mortar_spawn_positions.clear()
	_pending_bamboo_mortar_landing_positions.clear()
	_pending_bamboo_mortar_windup_durations.clear()
	_pending_bamboo_mortar_host_times.clear()


func queue_hydrangea_rain_visual(
	plant_net_id: int,
	action_id: int,
	target_position: Vector2,
	action_elapsed_seconds: float
) -> void:
	if (
		not _has_tower_mode()
		or not is_inside_tree()
		or not net_manager.is_host()
		or game == null
		or plant_net_id <= 0
		or action_id <= 0
		or not _is_finite_vector2(target_position)
		or not is_finite(action_elapsed_seconds)
		or action_elapsed_seconds < 0.0
	):
		return
	var hydrangea := _get_tower_plant(plant_net_id)
	if (
		hydrangea == null
		or not is_instance_valid(hydrangea)
		or hydrangea.get_script() != HYDRANGEA_RAIN_TOWER_SCRIPT
	):
		return
	_rpc_to_connected_clients(
		&"net_hydrangea_rain_visual",
		[
			plant_net_id,
			action_id,
			target_position,
			_get_net_time() - action_elapsed_seconds,
		]
	)


func queue_corn_machine_gun_burst_visual(
	plant_net_id: int,
	action_id: int,
	direction: Vector2
) -> void:
	if (
		not _has_tower_mode()
		or not is_inside_tree()
		or not net_manager.is_host()
		or game == null
		or plant_net_id <= 0
		or action_id <= 0
		or not _is_finite_vector2(direction)
		or direction.length_squared() <= 0.001
	):
		return
	var corn := _get_tower_plant(plant_net_id)
	if (
		corn == null
		or not is_instance_valid(corn)
		or corn.get_script() != CORN_MACHINE_GUN_SCRIPT
	):
		return
	_append_corn_machine_gun_burst_visual(
		plant_net_id,
		action_id,
		direction.normalized(),
		_get_net_time()
	)


func _append_corn_machine_gun_burst_visual(
	plant_net_id: int,
	action_id: int,
	direction: Vector2,
	host_action_time: float
) -> void:
	_pending_corn_machine_gun_burst_visuals.append(plant_net_id)
	_pending_corn_machine_gun_burst_action_ids.append(action_id)
	_pending_corn_machine_gun_burst_directions.append(direction)
	_pending_corn_machine_gun_burst_host_times.append(host_action_time)


func _clear_corn_machine_gun_burst_visuals() -> void:
	_pending_corn_machine_gun_burst_visuals.clear()
	_pending_corn_machine_gun_burst_action_ids.clear()
	_pending_corn_machine_gun_burst_directions.clear()
	_pending_corn_machine_gun_burst_host_times.clear()


func apply_authoritative_plant_enemy_damage(
	_damage_source_id: int,
	enemy: Enemy,
	damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> bool:
	if (
		not _has_tower_mode()
		or not net_manager.is_host()
		or game == null
		or enemy == null
		or damage <= 0
	):
		return false
	var enemy_net_id := int(
		game.multiplayer_enemy_ids_by_instance.get(enemy.get_instance_id(), 0)
	)
	if enemy_net_id <= 0:
		return false
	var safe_direction := impact_direction if _is_finite_vector2(impact_direction) else Vector2.ZERO
	return _apply_confirmed_enemy_damage(
		enemy_net_id,
		enemy,
		damage,
		safe_direction,
		damage_type
	)


func request_bamboo_mortar_target(
	owner: Node2D,
	minimum_range: float,
	maximum_range: float,
	callback: Callable
) -> bool:
	if not net_manager.is_host() or not _has_tower_mode():
		return false
	return tower_mode_adapter.request_runtime_bamboo_mortar_target(
		owner,
		minimum_range,
		maximum_range,
		callback
	)


func cancel_bamboo_mortar_target_request(owner: Node) -> void:
	if not _has_tower_mode():
		return
	tower_mode_adapter.cancel_runtime_bamboo_mortar_target_request(owner)


func select_bamboo_mortar_target_sync_for_fixture(
	center: Vector2,
	minimum_range: float,
	maximum_range: float
) -> Enemy:
	if not net_manager.is_host() or not _has_tower_mode():
		return null
	return tower_mode_adapter.select_runtime_bamboo_mortar_target_sync_for_fixture(
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
	if not net_manager.is_host() or not _has_tower_mode():
		return false
	return tower_mode_adapter.queue_runtime_bamboo_mortar_explosion(
		landing_position,
		inner_radius,
		outer_radius,
		inner_damage,
		outer_damage,
		damage_source_id
	)


func apply_authoritative_plant_enemy_damage_batch(
	_damage_source_id: int,
	enemy: Enemy,
	damage_amounts: PackedInt64Array,
	hit_counts: PackedInt32Array,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> bool:
	if (
		not _has_tower_mode()
		or not net_manager.is_host()
		or game == null
		or enemy == null
		or damage_amounts.is_empty()
	):
		return false
	var enemy_net_id := int(
		game.multiplayer_enemy_ids_by_instance.get(
			enemy.get_instance_id(),
			0
		)
	)
	if enemy_net_id <= 0:
		return false
	var safe_direction := (
		impact_direction
		if _is_finite_vector2(impact_direction)
		else Vector2.ZERO
	)
	return _apply_confirmed_enemy_damage_batch(
		enemy_net_id,
		enemy,
		damage_amounts,
		hit_counts,
		safe_direction,
		damage_type
	)


func get_bamboo_mortar_combat_metrics() -> Dictionary:
	if not _has_tower_mode():
		return {}
	return tower_mode_adapter.get_runtime_bamboo_mortar_combat_metrics()


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
	gameplay_gateway.attach_multiplayer_session(self)
	mode_adapter.attach_multiplayer_session(self)
	tower_mode_adapter = mode_adapter as TowerDefenseMultiplayerModeAdapter
	var tower_adapter := tower_mode_adapter
	var typed_net_manager := net_manager as NetManagerStore
	if typed_net_manager == null:
		push_error("MpGame: TransactionsCoordinator 缺少强类型 NetManagerStore。")
		_discard_unparented_game_runtime()
		return false
	transactions_coordinator.bind_session(
		self,
		game,
		mode_adapter,
		typed_net_manager,
		run_state,
		_suspended_embedded_participant_peer_ids
	)
	if tower_adapter != null:
		tower_economy_coordinator.bind_runtime(
			game,
			tower_adapter,
			run_state,
			typed_net_manager,
			_net_time_origin
		)
	else:
		tower_economy_coordinator.reset_session_state()
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
			tower_adapter.base_health_changed.connect(_on_host_base_health_changed)
			tower_adapter.xiaocong_fate_state_changed.connect(
				_on_host_xiaocong_fate_state_changed
			)
			tower_adapter.test_arena_manual_night_changed.connect(
				_on_host_test_arena_manual_night_changed
			)
			tower_adapter.plant_spawned.connect(_on_host_plant_spawned)
			tower_adapter.plant_placement_rejected.connect(
				_on_host_plant_placement_rejected
			)
			tower_adapter.plant_health_changed.connect(
				_on_host_plant_health_changed
			)
			tower_adapter.plant_damage_status_changed.connect(
				_on_host_plant_damage_status_changed
			)
			tower_adapter.plant_damage_applied.connect(
				_on_host_plant_damage_applied
			)
			tower_adapter.plant_healing_applied.connect(
				_on_host_plant_healing_applied
			)
			tower_adapter.plant_removed.connect(_on_host_plant_removed)
			tower_adapter.terrain_delta.connect(_on_host_terrain_delta)
			tower_adapter.inventory_changed.connect(
				_on_host_multiplayer_inventory_changed
			)
	if tower_adapter != null:
		tower_adapter.plant_placement_requested.connect(
			_on_local_plant_placement_requested
		)
		tower_adapter.inventory_plant_placement_requested.connect(
			_on_local_inventory_plant_placement_requested
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
	if net_manager.is_client():
		_client_has_terrain_snapshot = (
			not _has_tower_mode()
			or not tower_mode_adapter.supports_terrain_state()
		)
	run_state.set_active_multiplayer_peer(local_peer_id)
	if net_manager.is_host() and _has_tower_mode():
		_broadcast_base_health_snapshot()
	return true


func _discard_unparented_game_runtime() -> void:
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
	if _has_tower_mode() and tower_mode_adapter.supports_terrain_state():
		_client_waiting_for_terrain_snapshot = true
		_arm_terrain_snapshot_repair_watchdog()
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
	_runtime_network_metrics.record_state_repair()
	_send_terrain_snapshot_to_peer(peer_id)
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
	if _luoxi_offer_states_by_peer.has(peer_id):
		_send_luoxi_offer_state_to_peer(
			peer_id,
			_luoxi_offer_states_by_peer[peer_id] as Dictionary
		)
	_send_live_enemy_roster_to_peer(peer_id)
	_send_live_pickup_roster_to_peer(peer_id)
	if _has_tower_mode():
		var base_snapshot := tower_mode_adapter.get_base_health_snapshot()
		if not base_snapshot.is_empty():
			net_base_health_changed.rpc_id(
				peer_id,
				int(base_snapshot.get("current_health", 0)),
				int(base_snapshot.get("maximum_health", 1)),
				int(base_snapshot.get("revision", 0))
			)
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
		var fate_snapshot := tower_mode_adapter.get_xiaocong_fate_state_snapshot()
		if not fate_snapshot.is_empty():
			net_xiaocong_fate_state_changed.rpc_id(
				peer_id,
				fate_snapshot.duplicate(true)
			)
		if tower_mode_adapter.is_fate_interlude_active():
			_send_authoritative_player_positions_to_peer(peer_id)
	if (
		_has_tower_mode()
		and tower_mode_adapter.supports_test_arena_manual_night_sync()
	):
		net_test_arena_manual_night_changed.rpc_id(
			peer_id,
			tower_mode_adapter.get_test_arena_manual_night_enabled()
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
	_send_active_tango_electric_surges_to_peer(peer_id)
	_send_runtime_world_manifest_to_peer(peer_id)


func _send_active_tango_electric_surges_to_peer(target_peer_id: int) -> void:
	if not net_manager.is_host() or target_peer_id <= 0:
		return
	var now := _get_net_time()
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
			# The authoritative field owns roster retirement. Skipping an event at
			# its deadline avoids resurrecting an already-finishing visual while
			# still allowing its final damage catch-up to complete.
			continue
		var owner_player := game.get_player_for_peer(owner_peer_id)
		var buff_active := (
			_is_valid_tango_player(owner_player)
			and bool(owner_player.call("is_electric_surge_active"))
		)
		net_tango_electric_surge_started.rpc_id(
			target_peer_id,
			owner_peer_id,
			int(record.get("activation_id", 0)),
			record.get("origin", Vector2.ZERO) as Vector2,
			remaining_seconds,
			now,
			buff_active,
			int(record.get("request_id", 1)),
			int(record.get("charge_sequence", 0))
		)


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


func _send_terrain_snapshot_to_peer(peer_id: int) -> void:
	if (
		not net_manager.is_host()
		or not _has_tower_mode()
		or peer_id <= 0
		or not tower_mode_adapter.supports_terrain_state()
	):
		return
	var snapshot := tower_mode_adapter.get_terrain_snapshot()
	var revision := int(snapshot.get("revision", -1))
	var cell_xy: PackedInt32Array = snapshot.get("cell_xy", PackedInt32Array())
	var terrain_types: PackedInt32Array = snapshot.get(
		"terrain_types",
		PackedInt32Array()
	)
	if (
		revision < 0
		or not _is_valid_terrain_payload(
			cell_xy,
			terrain_types,
			TERRAIN_SNAPSHOT_CHUNK_MAX_CELLS * TERRAIN_SNAPSHOT_MAX_CHUNKS
		)
	):
		push_error("MpGame: authoritative terrain snapshot is invalid.")
		return
	var snapshot_id := _next_terrain_snapshot_id
	_next_terrain_snapshot_id += 1
	var cell_count := terrain_types.size()
	var chunk_count := maxi(
		ceili(float(cell_count) / float(TERRAIN_SNAPSHOT_CHUNK_MAX_CELLS)),
		1
	)
	for chunk_index in range(chunk_count):
		var start_cell := chunk_index * TERRAIN_SNAPSHOT_CHUNK_MAX_CELLS
		var end_cell := mini(start_cell + TERRAIN_SNAPSHOT_CHUNK_MAX_CELLS, cell_count)
		var chunk_cell_xy := PackedInt32Array()
		var chunk_terrain_types := PackedInt32Array()
		for cell_index in range(start_cell, end_cell):
			chunk_cell_xy.append(cell_xy[cell_index * 2])
			chunk_cell_xy.append(cell_xy[cell_index * 2 + 1])
			chunk_terrain_types.append(terrain_types[cell_index])
		_record_outbound_rpc(
			&"net_terrain_snapshot_chunk",
			[
				snapshot_id,
				revision,
				chunk_index,
				chunk_count,
				chunk_cell_xy,
				chunk_terrain_types,
			]
		)
		net_terrain_snapshot_chunk.rpc_id(
			peer_id,
			snapshot_id,
			revision,
			chunk_index,
			chunk_count,
			chunk_cell_xy,
			chunk_terrain_types
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
		for plant_snapshot in _get_tower_plant_snapshots():
			var plant_net_id := int(plant_snapshot.get("net_id", 0))
			if plant_net_id > 0:
				live_plant_ids.append(plant_net_id)
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
	_host_update_player_revives()
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
	_apply_authoritative_tango_charge_snapshot_ratios(states, snapshot_time)
	var batch := player_coordinator.build_host_snapshot_batch(
		states,
		client_peer_ids,
		snapshot_time,
		_player_health_revisions
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


func _apply_authoritative_tango_charge_snapshot_ratios(
	states: Array[SnapshotManager.PlayerState],
	sample_time: float
) -> void:
	for state in states:
		if state == null or state.character_id != &"tango":
			continue
		state.primary_cooldown_ratio = 0.0
		var charge := _active_tango_charges_by_peer.get(state.peer_id, {}) as Dictionary
		if charge.is_empty():
			continue
		var started_at := float(charge.get("started_at", sample_time))
		state.primary_cooldown_ratio = clampf(
			maxf(sample_time - started_at, 0.0) / TANGO_CHARGE_MAXIMUM_SECONDS,
			0.0,
			1.0
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
	if not peer_ids.is_empty():
		_record_outbound_rpc(method_name, args, peer_ids.size())
	for peer_id in peer_ids:
		var rpc_args: Array = [peer_id, method_name]
		rpc_args.append_array(args)
		callv("rpc_id", rpc_args)


func _record_outbound_rpc(
	method_name: StringName,
	args: Array,
	packet_count: int = 1
) -> void:
	if packet_count <= 0:
		return
	var channel := _get_rpc_traffic_channel(method_name)
	# Packet counts remain exact in production. Payload byte diagnostics are opt-in
	# because serializing live RPC arguments here would duplicate Godot's real RPC
	# serialization work. When enabled, one sample per method is refreshed every
	# fixed number of calls and reused as an explicitly approximate byte estimate.
	if not _rpc_payload_diagnostics_enabled:
		_runtime_network_metrics.record_packet(channel, 0, packet_count)
		return
	var call_count := int(_rpc_payload_call_counts.get(method_name, 0)) + 1
	_rpc_payload_call_counts[method_name] = call_count
	if (
		not _rpc_payload_sample_bytes.has(method_name)
		or call_count % RPC_PAYLOAD_DIAGNOSTIC_SAMPLE_INTERVAL == 0
	):
		_rpc_payload_sample_bytes[method_name] = var_to_bytes(args).size() + 16
		_rpc_payload_sample_count += 1
	var payload_bytes := int(_rpc_payload_sample_bytes.get(method_name, 0))
	_runtime_network_metrics.record_packet(
		channel,
		payload_bytes,
		packet_count
	)


func set_rpc_payload_diagnostics_enabled(enabled: bool) -> void:
	if _rpc_payload_diagnostics_enabled == enabled:
		return
	_rpc_payload_diagnostics_enabled = enabled
	_rpc_payload_call_counts.clear()
	_rpc_payload_sample_bytes.clear()
	_rpc_payload_sample_count = 0


func _get_rpc_traffic_channel(method_name: StringName) -> int:
	if (
		method_name == &"net_projectile_fired"
		or method_name == &"net_tango_laser_volley"
		or method_name == &"net_linglan_skill1_ring_batch"
		or method_name == &"net_plant_projectile_visual"
		or method_name == &"net_corn_machine_gun_burst_batch"
		or method_name == &"net_tiyi_sniper_hit_confirmed"
	):
		return _NetConstants.CH_PROJECTILE
	if TRANSACTION_RPC_METHODS.has(method_name):
		return _NetConstants.CH_TRANSACTION
	if FEEDBACK_RPC_METHODS.has(method_name):
		return _NetConstants.CH_FEEDBACK
	return _NetConstants.CH_WORLD_EVENT


func _update_snapshot_packet_warning_timer(delta: float) -> void:
	_snapshot_packet_warn_time_left = maxf(_snapshot_packet_warn_time_left - delta, 0.0)


func _record_snapshot_packet_size(snapshot_type: StringName, packet_bytes: int, entity_count: int) -> void:
	if snapshot_type == &"player":
		_runtime_network_metrics.record_packet(
			_NetConstants.CH_PLAYER_STATE,
			packet_bytes + 16
		)
		_max_player_snapshot_packet_bytes = maxi(_max_player_snapshot_packet_bytes, packet_bytes)
		if packet_bytes <= SNAPSHOT_PACKET_WARN_BYTES:
			return
		_large_player_snapshot_packet_count += 1
	elif snapshot_type == &"enemy":
		_runtime_network_metrics.record_packet(
			_NetConstants.CH_ENEMY_STATE,
			packet_bytes + 24
		)
		_max_enemy_snapshot_packet_bytes = maxi(_max_enemy_snapshot_packet_bytes, packet_bytes)
		_enemy_snapshot_payload_bytes_total += packet_bytes
		_enemy_snapshot_packet_count += 1
		if packet_bytes <= SNAPSHOT_PACKET_WARN_BYTES:
			return
		_large_enemy_snapshot_packet_count += 1
	else:
		return
	if _snapshot_packet_warn_time_left > 0.0:
		return
	_snapshot_packet_warn_time_left = SNAPSHOT_PACKET_WARN_INTERVAL_SECONDS
	if is_inside_tree():
		push_warning(
			"MpGame: %s snapshot packet is %d bytes for %d entities; monitor bandwidth under latency/loss."
			% [String(snapshot_type), packet_bytes, entity_count]
		)


func get_snapshot_packet_metrics() -> Dictionary:
	var runtime_metrics := _runtime_network_metrics.get_summary()
	var enemy_metrics := enemy_coordinator.get_snapshot_metrics()
	var pool_metrics: Dictionary = {}
	if game != null:
		var object_pool := game.get_node_or_null("SessionObjectPool") as SessionObjectPool
		if object_pool != null:
			pool_metrics = object_pool.get_all_metrics()
	return {
		"max_player_snapshot_packet_bytes": _max_player_snapshot_packet_bytes,
		"max_enemy_snapshot_packet_bytes": _max_enemy_snapshot_packet_bytes,
		"large_player_snapshot_packet_count": _large_player_snapshot_packet_count,
		"large_enemy_snapshot_packet_count": _large_enemy_snapshot_packet_count,
		"enemy_snapshot_payload_bytes_total": _enemy_snapshot_payload_bytes_total,
		"enemy_snapshot_packet_count": _enemy_snapshot_packet_count,
		"enemy_snapshot_batch_count": int(enemy_metrics.get("enemy_snapshot_batch_count", 0)),
		"player_snapshot_encode_count": player_coordinator.get_snapshot_encode_count(),
		"enemy_snapshot_chunk_encode_count": int(
			enemy_metrics.get("enemy_snapshot_chunk_encode_count", 0)
		),
		"player_snapshot_cohort_size": player_coordinator.get_snapshot_cohort_size(),
		"enemy_snapshot_cohort_size": int(
			enemy_metrics.get("enemy_snapshot_cohort_size", 0)
		),
		"enemy_snapshot_completed_batch_count": int(
			enemy_metrics.get("enemy_snapshot_completed_batch_count", 0)
		),
		"enemy_snapshot_incomplete_batch_evict_count": int(
			enemy_metrics.get("enemy_snapshot_incomplete_batch_evict_count", 0)
		),
		"enemy_snapshot_stale_chunk_count": int(
			enemy_metrics.get("enemy_snapshot_stale_chunk_count", 0)
		),
		"offscreen_enemy_proxy_count": int(
			enemy_metrics.get("offscreen_enemy_proxy_count", 0)
		),
		"rpc_payload_diagnostics_enabled": _rpc_payload_diagnostics_enabled,
		"rpc_payload_diagnostic_sample_interval": RPC_PAYLOAD_DIAGNOSTIC_SAMPLE_INTERVAL,
		"rpc_payload_diagnostic_sample_count": _rpc_payload_sample_count,
		"channel_metrics": runtime_metrics.get("channels", []),
		"state_repair_count": runtime_metrics.get("state_repair_count", 0),
		"transaction_latency_sample_count": runtime_metrics.get(
			"transaction_latency_sample_count",
			0
		),
		"transaction_latency_p95_ms": runtime_metrics.get(
			"transaction_latency_p95_ms",
			0.0
		),
		"pool_metrics": pool_metrics,
	}


func _update_public_room_keepalive(delta: float) -> void:
	if not _should_send_public_room_keepalive():
		_public_room_keepalive_time_left = 0.0
		return
	if _public_room_keepalive_in_flight:
		return
	_public_room_keepalive_time_left -= delta
	if _public_room_keepalive_time_left > 0.0:
		return
	_send_public_room_keepalive()


func _should_send_public_room_keepalive() -> bool:
	if public_room_keepalive_request == null or net_manager == null:
		return false
	if not net_manager.is_host():
		return false
	if int(net_manager.get("conn_mode")) != int(NetManagerStore.ConnMode.RELAY):
		return false
	if not bool(net_manager.get("public_is_host")):
		return false
	return (
		not str(net_manager.get("public_room_id")).strip_edges().is_empty()
		and not str(net_manager.get("public_host_token")).strip_edges().is_empty()
	)


func _send_public_room_keepalive() -> void:
	var room_id := str(net_manager.get("public_room_id")).strip_edges()
	var host_token := str(net_manager.get("public_host_token")).strip_edges()
	if room_id.is_empty() or host_token.is_empty():
		return
	var body := JSON.stringify({"host_token": host_token})
	var headers := PackedStringArray(["Content-Type: application/json"])
	var err := public_room_keepalive_request.request(
		"%s/rooms/%s/keepalive" % [_NetConstants.PUBLIC_LOBBY_API_BASE_URL, room_id],
		headers,
		HTTPClient.METHOD_POST,
		body
	)
	if err != OK:
		_public_room_keepalive_time_left = _NetConstants.PUBLIC_ROOM_KEEPALIVE_INTERVAL_SECONDS
		push_warning("MpGame: 公网房间续租请求启动失败: %s" % error_string(err))
		return
	_public_room_keepalive_in_flight = true


func _on_public_room_keepalive_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	_public_room_keepalive_in_flight = false
	_public_room_keepalive_time_left = _NetConstants.PUBLIC_ROOM_KEEPALIVE_INTERVAL_SECONDS
	if not _should_send_public_room_keepalive():
		return
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		var error_body_text := body.get_string_from_utf8()
		push_warning(
			"MpGame: 公网房间续租失败 result=%d status=%d body=%s"
			% [result, response_code, error_body_text.left(160)]
		)
		return

	var parsed: Variant = null
	var response_body_text := body.get_string_from_utf8()
	if not response_body_text.is_empty():
		parsed = JSON.parse_string(response_body_text)
	var parsed_dict := parsed as Dictionary
	if parsed_dict != null and parsed_dict.has("relay_running") and not bool(parsed_dict["relay_running"]):
		push_warning("MpGame: 公网房间续租成功，但云端 Relay 进程已不在运行。")


func _client_physics_tick(frame: int) -> void:
	if not _client_host_game_ready:
		return
	_input_frames_since_last_send += 1
	var buttons := 0
	if Input.is_action_just_pressed("reload"):
		buttons |= INPUT_BUTTON_RELOAD
	if _pending_dash_input_packets > 0:
		buttons |= INPUT_BUTTON_DASH
	if frame % _NetConstants.INPUT_SEND_INTERVAL_FRAMES == 0 or buttons != 0:
		_client_send_input_if_needed(buttons)
		if (buttons & INPUT_BUTTON_DASH) != 0:
			_pending_dash_input_packets -= 1
			if _pending_dash_input_packets <= 0:
				_pending_dash_request_sequence = 0
				_pending_dash_direction = Vector2.ZERO
				_pending_dash_start_move_input = Vector2.ZERO


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
		_pending_dash_request_sequence,
		_pending_dash_direction,
		_pending_dash_start_move_input
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
		_local_tango_active_request_id > 0
	)
	for peer_id in stale_peer_ids:
		_clear_peer_network_state(peer_id)
		game.remove_multiplayer_player(peer_id)


func _get_player_primary_cooldown_ratio(player_node: Player) -> float:
	if player_node == null or not is_instance_valid(player_node):
		return 0.0
	return clampf(player_node.get_primary_cooldown_ratio(), 0.0, 1.0)


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
	if not net_manager.is_host() or game == null:
		return
	if sender_id <= 0:
		return
	var player_node := game.get_player_for_peer(sender_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if player_node.is_dead or player_node.controls_locked:
		net_player_state_corrected.rpc_id(sender_id, player_node.global_position, player_node.velocity)
		return
	if not _accept_client_player_state(sender_id, sequence, reported_position, reported_velocity):
		net_player_state_corrected.rpc_id(sender_id, player_node.global_position, player_node.velocity)
		return
	var combat_actions_locked := player_node.are_combat_actions_locked()
	if combat_actions_locked:
		shoot_input = Vector2.ZERO
	var use_reload: bool = (
		(buttons & INPUT_BUTTON_RELOAD) != 0
		and not combat_actions_locked
	)
	var use_dash: bool = (buttons & INPUT_BUTTON_DASH) != 0
	if use_dash:
		var dash_movement_evidence := dash_start_move_input
		if dash_movement_evidence.length_squared() <= 0.001:
			dash_movement_evidence = move_input
		if dash_movement_evidence.length_squared() <= 0.001:
			dash_movement_evidence = reported_velocity
		_try_accept_client_dash_request(
			sender_id,
			player_node,
			dash_request_sequence,
			dash_direction,
			dash_movement_evidence
		)
	_apply_accepted_client_player_state(
		sender_id,
		player_node,
		reported_position,
		reported_velocity,
		shoot_input,
		false,
		use_reload
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
	if sender_id <= 0 or player_node == null or not is_instance_valid(player_node):
		return
	player_node.apply_remote_multiplayer_state(
		reported_position,
		reported_velocity,
		shoot_input,
		use_skill1,
		use_reload
	)
	player_coordinator.remember_latest_client_state(
		true,
		sender_id,
		reported_position,
		reported_velocity,
		player_node.get_multiplayer_facing_id(),
		player_node.get_multiplayer_anim_state()
	)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_player_dash_requested(
	dash_request_sequence: int,
	direction: Vector2,
	start_move_input: Vector2
) -> void:
	if not net_manager.is_host() or game == null:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not _consume_remote_player_action_admission(sender_id):
		return
	var player_node := game.get_player_for_peer(sender_id)
	_try_accept_client_dash_request(
		sender_id,
		player_node,
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
	if peer_id <= 0 or dash_request_sequence <= 0:
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
	var accepted_at := _get_net_time()
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


func _broadcast_player_dash_confirmed(
	peer_id: int,
	direction: Vector2,
	dash_request_sequence: int
) -> void:
	if not net_manager.is_host() or peer_id <= 0 or dash_request_sequence <= 0:
		return
	_rpc_to_connected_clients(
		&"net_player_dash_confirmed",
		[peer_id, direction.normalized(), dash_request_sequence]
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_player_dash_confirmed(
	player_peer_id: int,
	direction: Vector2,
	dash_request_sequence: int
) -> void:
	if game == null or not is_client_view_runtime():
		return
	if player_peer_id == _get_client_view_local_peer_id():
		if dash_request_sequence == _pending_dash_request_sequence:
			_pending_dash_input_packets = 0
			_pending_dash_request_sequence = 0
			_pending_dash_direction = Vector2.ZERO
			_pending_dash_start_move_input = Vector2.ZERO
		return
	if dash_request_sequence <= int(_last_dash_confirmed_sequences.get(player_peer_id, 0)):
		return
	var player_node := game.get_player_for_peer(player_peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	_last_dash_confirmed_sequences[player_peer_id] = dash_request_sequence
	player_node.play_remote_dash_visual(direction)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_hoe_primary_attack_requested(direction: Vector2, request_id: int = 0) -> void:
	if not net_manager.is_host() or game == null:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not _consume_remote_player_action_admission(sender_id):
		return
	_apply_authoritative_hoe_action(sender_id, HOE_ACTION_PRIMARY, direction, request_id)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_hoe_whirlwind_requested(request_id: int = 0) -> void:
	if not net_manager.is_host() or game == null:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not _consume_remote_player_action_admission(sender_id):
		return
	_apply_authoritative_hoe_action(sender_id, HOE_ACTION_WHIRLWIND, Vector2.ZERO, request_id)


func _apply_authoritative_hoe_action(
	peer_id: int,
	action_kind: StringName,
	direction: Vector2,
	request_id: int = 0
) -> bool:
	if not net_manager.is_host() or game == null or peer_id <= 0:
		return false
	var player_node := game.get_player_for_peer(peer_id)
	if not _is_valid_hoe_cat_player(player_node):
		return false
	if request_id > 0:
		var last_request_id := int(_last_hoe_action_request_ids.get(peer_id, 0))
		if request_id <= last_request_id:
			return false
		_last_hoe_action_request_ids[peer_id] = request_id
	var safe_direction := _sanitize_hoe_action_direction(player_node, direction)
	var succeeded := false
	match action_kind:
		HOE_ACTION_PRIMARY:
			succeeded = bool(
				player_node.call("try_authoritative_hoe_primary_attack", safe_direction)
			)
		HOE_ACTION_WHIRLWIND:
			succeeded = bool(player_node.call("try_authoritative_hoe_whirlwind"))
		_:
			return false
	if not succeeded:
		if request_id > 0 and peer_id != _get_local_peer_id():
			net_hoe_action_confirmed.rpc_id(
				peer_id,
				peer_id,
				String(action_kind),
				safe_direction,
				int(_hoe_action_sequences_by_peer.get(peer_id, 0)),
				request_id,
				false,
				_get_player_primary_cooldown_ratio(player_node),
				player_node.skill1_charge
			)
		return false
	var action_sequence := int(_hoe_action_sequences_by_peer.get(peer_id, 0)) + 1
	_hoe_action_sequences_by_peer[peer_id] = action_sequence
	_rpc_to_connected_clients(
		&"net_hoe_action_confirmed",
		[
			peer_id,
			String(action_kind),
			safe_direction,
			action_sequence,
			request_id,
			true,
			_get_player_primary_cooldown_ratio(player_node),
			player_node.skill1_charge,
		]
	)
	return true


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
	if game == null or multiplayer.get_remote_sender_id() != _get_host_peer_id():
		return
	if peer_id <= 0 or action_sequence < 0:
		return
	var action_kind := StringName(action_kind_text)
	if action_kind != HOE_ACTION_PRIMARY and action_kind != HOE_ACTION_WHIRLWIND:
		return
	var player_node := game.get_player_for_peer(peer_id)
	if not _is_valid_hoe_cat_player(player_node):
		return
	var safe_direction := _sanitize_hoe_action_direction(player_node, direction)
	if peer_id == _get_client_view_local_peer_id() and request_id > 0:
		player_node.call(
			"reconcile_predicted_hoe_action",
			request_id,
			accepted,
			action_kind,
			cooldown_ratio,
			skill_charge
		)
		return
	if accepted:
		player_node.call("play_remote_hoe_action", action_kind, safe_direction, action_sequence)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_tango_electric_surge_requested(request_id: int) -> void:
	if not net_manager.is_host() or game == null:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not _consume_remote_player_action_admission(sender_id)
		or request_id <= 0
	):
		return
	_apply_authoritative_tango_electric_surge_request(sender_id, request_id)


func _apply_authoritative_tango_electric_surge_request(
	peer_id: int,
	request_id: int
) -> bool:
	if not net_manager.is_host() or game == null or peer_id <= 0 or request_id <= 0:
		return false
	var last_request_id := int(
		_last_tango_electric_surge_request_ids.get(peer_id, 0)
	)
	if request_id <= last_request_id:
		return false
	_last_tango_electric_surge_request_ids[peer_id] = request_id
	if _active_tango_electric_surges_by_peer.has(peer_id):
		return false
	var player_node := game.get_player_for_peer(peer_id)
	if not _is_valid_tango_player(player_node):
		return false
	var activation_id := int(
		_tango_electric_surge_sequences_by_peer.get(peer_id, 0)
	) + 1
	var auto_fire_charge_sequence := int(
		_tango_charge_sequences_by_peer.get(peer_id, 0)
	) + 1
	var origin := player_node.global_position
	if not bool(player_node.call(
		"try_start_authoritative_electric_surge",
		activation_id,
		origin,
		auto_fire_charge_sequence
	)):
		return false
	# A successful surge owns Tango's firing state for its complete lifetime. Retire
	# an ordinary charge first so its later release/cancel cannot overwrite the
	# automatic barrage. Both terminal and surge events use reliable channel 5,
	# preserving this order for replicas.
	if _active_tango_charges_by_peer.has(peer_id):
		_cancel_authoritative_tango_charge(peer_id, true)
	# Automatic volleys still use the established projectile protocol. Allocate a
	# fresh charge sequence without manufacturing a synthetic input request so Host
	# registration and client de-duplication share one activation-owned identity.
	_tango_charge_sequences_by_peer[peer_id] = auto_fire_charge_sequence
	var started_at := _get_net_time()
	var buff_active := bool(player_node.call("is_electric_surge_active"))
	_tango_electric_surge_sequences_by_peer[peer_id] = activation_id
	_active_tango_electric_surges_by_peer[peer_id] = {
		"activation_id": activation_id,
		"origin": origin,
		"started_at": started_at,
		"duration": TANGO_ELECTRIC_SURGE_DURATION_SECONDS,
		"request_id": request_id,
		"charge_sequence": auto_fire_charge_sequence,
	}
	_rpc_to_connected_clients(
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
	if game == null:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id > 0 and sender_id != _get_host_peer_id():
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
	var player_node := game.get_player_for_peer(peer_id)
	var is_recovery_replay := activation_id == last_seen_activation_id
	var recovery_record: Dictionary = {}
	if is_recovery_replay:
		recovery_record = _active_tango_electric_surges_by_peer.get(
			peer_id,
			{}
		) as Dictionary
		if int(recovery_record.get("activation_id", 0)) != activation_id:
			return
		# Buff lifetime can end before its independent world field. Once Host has
		# reported it inactive, an older recovery state must never reactivate it.
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
	# Replay packets carry a Host-computed remaining duration. A previously
	# established clock offset may trim transport age, but this event must never
	# establish/update the global offset: its timestamp can describe a late join
	# and is not a fresh clock sample.
	if _has_host_time_offset:
		var local_sent_at := _map_host_timestamp_to_client_time(host_sent_at, false)
		remaining = maxf(
			remaining - maxf(_get_net_time() - local_sent_at, 0.0),
			0.0
		)
	if is_recovery_replay:
		if remaining <= 0.0:
			_active_tango_electric_surges_by_peer.erase(peer_id)
			if bool(recovery_record.get("owner_disconnected", false)):
				_clear_tango_electric_surge_sequence_guards(peer_id)
			if _is_valid_tango_player(player_node):
				player_node.call("cancel_remote_electric_surge", activation_id)
			return
		if buff_active and _is_valid_tango_player(player_node):
			player_node.call(
				"play_remote_electric_surge_started",
				activation_id,
				origin,
				remaining,
				false,
				auto_fire_charge_sequence
			)
		elif _is_valid_tango_player(player_node):
			player_node.call("cancel_remote_electric_surge", activation_id)
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
		"owner_disconnected": not _is_valid_tango_player(player_node),
	}
	# MpGame owns the one world-visual spawn per accepted activation. Player state
	# recovery is separate, so a Player reconstructed after an ownerless replay
	# cannot create a second overlapping field.
	spawn_remote_tango_electric_surge_visual_field(
		activation_id,
		origin,
		remaining
	)
	if buff_active and _is_valid_tango_player(player_node):
		player_node.call(
			"play_remote_electric_surge_started",
			activation_id,
			origin,
			remaining,
			false,
			auto_fire_charge_sequence
		)


@rpc("authority", "call_remote", "reliable", 5)
func net_tango_electric_surge_finished(peer_id: int, activation_id: int) -> void:
	if game == null or peer_id <= 0 or activation_id <= 0:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id > 0 and sender_id != _get_host_peer_id():
		return
	var record := _active_tango_electric_surges_by_peer.get(peer_id, {}) as Dictionary
	if int(record.get("activation_id", 0)) != activation_id:
		return
	_active_tango_electric_surges_by_peer.erase(peer_id)
	if bool(record.get("owner_disconnected", false)):
		_clear_tango_electric_surge_sequence_guards(peer_id)
	var player_node := game.get_player_for_peer(peer_id)
	if _is_valid_tango_player(player_node):
		player_node.call("cancel_remote_electric_surge", activation_id)


func _finish_authoritative_tango_electric_surge(
	peer_id: int,
	activation_id: int
) -> void:
	var record := _active_tango_electric_surges_by_peer.get(peer_id, {}) as Dictionary
	if int(record.get("activation_id", 0)) != activation_id:
		return
	_active_tango_electric_surges_by_peer.erase(peer_id)
	_rpc_to_connected_clients(
		&"net_tango_electric_surge_finished",
		[peer_id, activation_id]
	)
	if bool(record.get("owner_disconnected", false)):
		_clear_tango_electric_surge_sequence_guards(peer_id)


func _clear_tango_electric_surge_sequence_guards(peer_id: int) -> void:
	_tango_electric_surge_sequences_by_peer.erase(peer_id)
	_last_tango_electric_surge_request_ids.erase(peer_id)
	_last_tango_electric_surge_seen_by_peer.erase(peer_id)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_tango_charge_started_requested(direction: Vector2, request_id: int) -> void:
	if not net_manager.is_host() or game == null:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not _consume_remote_player_action_admission(sender_id)
		or request_id <= 0
	):
		return
	_apply_authoritative_tango_charge_started(sender_id, direction, request_id)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_tango_charge_released_requested(direction: Vector2, request_id: int) -> void:
	if not net_manager.is_host() or game == null:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not _consume_remote_player_action_admission(sender_id)
		or request_id <= 0
	):
		return
	_apply_authoritative_tango_charge_released(sender_id, direction, request_id)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_tango_charge_cancelled_requested(request_id: int) -> void:
	if not net_manager.is_host() or game == null:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not _consume_remote_player_action_admission(sender_id)
		or request_id <= 0
	):
		return
	_apply_authoritative_tango_charge_cancelled(sender_id, request_id)


func _apply_authoritative_tango_charge_started(
	peer_id: int,
	direction: Vector2,
	request_id: int
) -> bool:
	if not net_manager.is_host() or game == null or peer_id <= 0 or request_id <= 0:
		return false
	var last_request_id := int(_last_tango_charge_request_ids.get(peer_id, 0))
	if request_id <= last_request_id:
		return false
	_last_tango_charge_request_ids[peer_id] = request_id
	if not _is_finite_vector2(direction) or _active_tango_charges_by_peer.has(peer_id):
		_send_tango_charge_rejected(peer_id, request_id, TANGO_CHARGE_PHASE_START)
		return false
	var player_node := game.get_player_for_peer(peer_id)
	if not _is_valid_tango_player(player_node):
		_send_tango_charge_rejected(peer_id, request_id, TANGO_CHARGE_PHASE_START)
		return false
	var safe_direction := _sanitize_tango_charge_direction(player_node, direction)
	if not bool(player_node.call("try_authoritative_tango_charge_started", safe_direction)):
		_send_tango_charge_rejected(peer_id, request_id, TANGO_CHARGE_PHASE_START)
		return false
	var charge_sequence := int(_tango_charge_sequences_by_peer.get(peer_id, 0)) + 1
	_tango_charge_sequences_by_peer[peer_id] = charge_sequence
	if (
		bool(player_node.call("is_electric_surge_active"))
		and bool(player_node.call("is_tango_barrage_active"))
	):
		# 电能涌动期间由 Host 直接进入满充弹幕；客户端仍只收到既有的
		# authoritative release 终端，因此倍率、持续时间和齐射序列都无法自报。
		_rpc_to_connected_clients(
			&"net_tango_charge_released",
			[peer_id, safe_direction, 1.0, charge_sequence, request_id]
		)
		return true
	if not bool(player_node.call("is_tango_charge_active")):
		_send_tango_charge_rejected(peer_id, request_id, TANGO_CHARGE_PHASE_START)
		return false
	_active_tango_charges_by_peer[peer_id] = {
		"request_id": request_id,
		"sequence": charge_sequence,
		"started_at": _get_net_time(),
	}
	_rpc_to_connected_clients(
		&"net_tango_charge_started",
		[peer_id, safe_direction, charge_sequence, request_id]
	)
	return true


func _apply_authoritative_tango_charge_released(
	peer_id: int,
	direction: Vector2,
	request_id: int
) -> bool:
	if not net_manager.is_host() or game == null or peer_id <= 0 or request_id <= 0:
		return false
	var charge := _active_tango_charges_by_peer.get(peer_id, {}) as Dictionary
	if charge.is_empty() or int(charge.get("request_id", 0)) != request_id:
		_send_tango_charge_rejected(peer_id, request_id, TANGO_CHARGE_PHASE_RELEASE)
		return false
	var charge_sequence := int(charge.get("sequence", 0))
	if not _is_finite_vector2(direction) or charge_sequence <= 0:
		_cancel_authoritative_tango_charge(peer_id, true, request_id)
		_send_tango_charge_rejected(peer_id, request_id, TANGO_CHARGE_PHASE_RELEASE)
		return false
	var player_node := game.get_player_for_peer(peer_id)
	if not _is_valid_tango_player(player_node):
		_cancel_authoritative_tango_charge(peer_id, true, request_id)
		_send_tango_charge_rejected(peer_id, request_id, TANGO_CHARGE_PHASE_RELEASE)
		return false
	var elapsed := maxf(_get_net_time() - float(charge.get("started_at", 0.0)), 0.0)
	if elapsed + TANGO_CHARGE_THRESHOLD_EPSILON < TANGO_CHARGE_MINIMUM_SECONDS:
		_cancel_authoritative_tango_charge(peer_id, true, request_id)
		return true
	var charge_ratio := clampf(
		(elapsed - TANGO_CHARGE_MINIMUM_SECONDS)
		/ (TANGO_CHARGE_MAXIMUM_SECONDS - TANGO_CHARGE_MINIMUM_SECONDS),
		0.0,
		1.0
	)
	var safe_direction := _sanitize_tango_charge_direction(player_node, direction)
	var result_variant: Variant = player_node.call(
		"try_authoritative_tango_charge_released",
		safe_direction,
		charge_ratio
	)
	if not (result_variant is Dictionary):
		_cancel_authoritative_tango_charge(peer_id, true, request_id)
		_send_tango_charge_rejected(peer_id, request_id, TANGO_CHARGE_PHASE_RELEASE)
		return false
	var result := result_variant as Dictionary
	if not bool(result.get("accepted", false)) or not bool(result.get("fired", false)):
		_cancel_authoritative_tango_charge(peer_id, true, request_id)
		_send_tango_charge_rejected(peer_id, request_id, TANGO_CHARGE_PHASE_RELEASE)
		return false
	_active_tango_charges_by_peer.erase(peer_id)
	_rpc_to_connected_clients(
		&"net_tango_charge_released",
		[peer_id, safe_direction, charge_ratio, charge_sequence, request_id]
	)
	return true


func _apply_authoritative_tango_charge_cancelled(peer_id: int, request_id: int) -> bool:
	if not net_manager.is_host() or game == null or peer_id <= 0 or request_id <= 0:
		return false
	var charge := _active_tango_charges_by_peer.get(peer_id, {}) as Dictionary
	if charge.is_empty() or int(charge.get("request_id", 0)) != request_id:
		_send_tango_charge_rejected(peer_id, request_id, TANGO_CHARGE_PHASE_CANCEL)
		return false
	_cancel_authoritative_tango_charge(peer_id, true, request_id)
	return true


func _cancel_authoritative_tango_charge(
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
	if peer_id == _get_local_peer_id() and resolved_request_id == _local_tango_active_request_id:
		_local_tango_active_request_id = 0
		_local_tango_release_pending = false
	var player_node := game.get_player_for_peer(peer_id) if game != null else null
	if _is_valid_tango_player(player_node):
		player_node.call("cancel_authoritative_tango_charge")
	if broadcast_cancel and charge_sequence > 0:
		_rpc_to_connected_clients(
			&"net_tango_charge_cancelled",
			[peer_id, charge_sequence, resolved_request_id]
		)


func _update_authoritative_tango_charge_lifecycle() -> void:
	if _active_tango_charges_by_peer.is_empty() or game == null:
		return
	var cancelled_peer_ids: Array[int] = []
	for peer_id_variant in _active_tango_charges_by_peer.keys():
		var peer_id := int(peer_id_variant)
		var player_node := game.get_player_for_peer(peer_id)
		if (
			_is_valid_tango_player(player_node)
			and bool(player_node.call("is_tango_charge_active"))
		):
			continue
		cancelled_peer_ids.append(peer_id)
	for peer_id in cancelled_peer_ids:
		_cancel_authoritative_tango_charge(peer_id, true)


func _send_tango_charge_rejected(peer_id: int, request_id: int, phase_text: String) -> void:
	if peer_id <= 0 or request_id <= 0 or peer_id == _get_host_peer_id():
		return
	net_tango_charge_rejected.rpc_id(peer_id, peer_id, request_id, phase_text)


@rpc("authority", "call_remote", "reliable", 5)
func net_tango_charge_started(
	peer_id: int,
	direction: Vector2,
	charge_sequence: int,
	request_id: int
) -> void:
	if game == null or multiplayer.get_remote_sender_id() != _get_host_peer_id():
		return
	if peer_id <= 0 or charge_sequence <= 0 or request_id <= 0 or not _is_finite_vector2(direction):
		return
	if charge_sequence <= int(_tango_charge_sequences_by_peer.get(peer_id, 0)):
		return
	var player_node := game.get_player_for_peer(peer_id)
	if not _is_valid_tango_player(player_node):
		return
	var safe_direction := _sanitize_tango_charge_direction(player_node, direction)
	_tango_charge_sequences_by_peer[peer_id] = charge_sequence
	if peer_id == _get_client_view_local_peer_id():
		if request_id != _local_tango_active_request_id:
			return
		player_node.call(
			"reconcile_predicted_tango_charge_started",
			safe_direction,
			charge_sequence
		)
		return
	player_node.call("play_remote_tango_charge_started", safe_direction, charge_sequence)


@rpc("authority", "call_remote", "reliable", 5)
func net_tango_charge_released(
	peer_id: int,
	direction: Vector2,
	charge_ratio: float,
	charge_sequence: int,
	request_id: int
) -> void:
	if game == null or multiplayer.get_remote_sender_id() != _get_host_peer_id():
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
	var player_node := game.get_player_for_peer(peer_id)
	if not _is_valid_tango_player(player_node):
		return
	if charge_sequence > last_charge_sequence:
		_tango_charge_sequences_by_peer[peer_id] = charge_sequence
	var safe_direction := _sanitize_tango_charge_direction(player_node, direction)
	if peer_id == _get_client_view_local_peer_id():
		if request_id != _local_tango_active_request_id:
			return
		player_node.call(
			"reconcile_predicted_tango_barrage_started",
			safe_direction,
			charge_ratio,
			charge_sequence
		)
		_local_tango_active_request_id = 0
		_local_tango_release_pending = false
		return
	player_node.call(
		"play_remote_tango_barrage_started",
		safe_direction,
		charge_ratio,
		charge_sequence
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_tango_charge_cancelled(
	peer_id: int,
	charge_sequence: int,
	request_id: int
) -> void:
	if game == null or multiplayer.get_remote_sender_id() != _get_host_peer_id():
		return
	var last_charge_sequence := int(_tango_charge_sequences_by_peer.get(peer_id, 0))
	if (
		peer_id <= 0
		or charge_sequence <= 0
		or request_id <= 0
		or charge_sequence < last_charge_sequence
	):
		return
	var player_node := game.get_player_for_peer(peer_id)
	if not _is_valid_tango_player(player_node):
		return
	if charge_sequence > last_charge_sequence:
		_tango_charge_sequences_by_peer[peer_id] = charge_sequence
	if peer_id == _get_client_view_local_peer_id():
		if request_id != _local_tango_active_request_id:
			return
		player_node.call("play_remote_tango_charge_cancelled", charge_sequence)
		_local_tango_active_request_id = 0
		_local_tango_release_pending = false
		return
	player_node.call("play_remote_tango_charge_cancelled", charge_sequence)


@rpc("authority", "call_remote", "reliable", 5)
func net_tango_charge_rejected(peer_id: int, request_id: int, phase_text: String) -> void:
	if game == null or multiplayer.get_remote_sender_id() != _get_host_peer_id():
		return
	if (
		peer_id != _get_client_view_local_peer_id()
		or request_id <= 0
		or (
			phase_text != TANGO_CHARGE_PHASE_START
			and phase_text != TANGO_CHARGE_PHASE_RELEASE
			and phase_text != TANGO_CHARGE_PHASE_CANCEL
		)
	):
		return
	# A rejection can arrive after the request it belongs to was already cancelled.
	# Never let that stale terminal tear down a newer local prediction.
	if request_id != _local_tango_active_request_id:
		return
	_local_tango_active_request_id = 0
	_local_tango_release_pending = false
	var player_node := game.get_player_for_peer(peer_id)
	if _is_valid_tango_player(player_node) and player_node.has_method("reject_predicted_tango_charge"):
		player_node.call("reject_predicted_tango_charge")


@rpc("any_peer", "call_remote", "reliable", 5)
func net_tiyi_high_noon_requested(activation_id: int) -> void:
	if not net_manager.is_host() or game == null:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not _consume_remote_player_action_admission(sender_id)
		or activation_id <= 0
	):
		return
	_apply_authoritative_tiyi_high_noon_request(sender_id, activation_id)


func _apply_authoritative_tiyi_high_noon_request(
	peer_id: int,
	activation_id: int
) -> bool:
	if not net_manager.is_host() or game == null or peer_id <= 0 or activation_id <= 0:
		return false
	var player_node := game.get_player_for_peer(peer_id)
	if not _is_valid_tiyi_player(player_node):
		return false
	if _active_tiyi_activations_by_peer.has(peer_id):
		return false
	if activation_id <= int(_tiyi_activation_sequences_by_peer.get(peer_id, 0)):
		return false
	if not bool(player_node.call("try_start_authoritative_high_noon", activation_id)):
		return false
	_tiyi_activation_sequences_by_peer[peer_id] = activation_id
	_active_tiyi_activations_by_peer[peer_id] = activation_id
	_tiyi_target_ids_by_peer[peer_id] = PackedInt32Array()
	_rpc_to_connected_clients(
		&"net_tiyi_high_noon_started",
		[peer_id, activation_id]
	)
	if player_node.has_method("sync_authoritative_high_noon_targets"):
		player_node.call("sync_authoritative_high_noon_targets")
	return true


@rpc("authority", "call_remote", "reliable", 5)
func net_tiyi_high_noon_started(peer_id: int, activation_id: int) -> void:
	if game == null or activation_id <= 0:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id > 0 and sender_id != _get_host_peer_id():
		return
	if _active_tiyi_activations_by_peer.has(peer_id):
		return
	if activation_id <= int(_last_tiyi_activation_seen_by_peer.get(peer_id, 0)):
		return
	var player_node := game.get_player_for_peer(peer_id)
	if not _is_valid_tiyi_player(player_node):
		return
	if bool(player_node.call("is_high_noon_active")):
		return
	_last_tiyi_activation_seen_by_peer[peer_id] = activation_id
	_active_tiyi_activations_by_peer[peer_id] = activation_id
	_tiyi_target_ids_by_peer[peer_id] = PackedInt32Array()
	player_node.call("play_remote_high_noon_started", activation_id)


@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_tiyi_high_noon_targets(
	peer_id: int,
	activation_id: int,
	target_ids: PackedInt32Array
) -> void:
	if game == null or activation_id <= 0:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id > 0 and sender_id != _get_host_peer_id():
		return
	if int(_active_tiyi_activations_by_peer.get(peer_id, 0)) != activation_id:
		return
	var player_node := game.get_player_for_peer(peer_id)
	if not _is_valid_tiyi_player(player_node):
		return
	var sanitized_target_ids := _sanitize_tiyi_target_ids(target_ids, false)
	_tiyi_target_ids_by_peer[peer_id] = sanitized_target_ids
	player_node.call("apply_remote_high_noon_targets", activation_id, sanitized_target_ids)


@rpc("authority", "call_remote", "reliable", 5)
func net_tiyi_high_noon_finished(
	peer_id: int,
	activation_id: int,
	target_ids: PackedInt32Array,
	hit_positions: PackedVector2Array
) -> void:
	if game == null or activation_id <= 0:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id > 0 and sender_id != _get_host_peer_id():
		return
	if int(_active_tiyi_activations_by_peer.get(peer_id, 0)) != activation_id:
		return
	var player_node := game.get_player_for_peer(peer_id)
	if not _is_valid_tiyi_player(player_node):
		return
	var target_count := mini(
		mini(target_ids.size(), hit_positions.size()),
		TIYI_HIGH_NOON_MAX_TARGETS
	)
	var sanitized_target_ids := PackedInt32Array()
	var sanitized_hit_positions := PackedVector2Array()
	var seen_ids: Dictionary = {}
	for target_index in range(target_count):
		var enemy_net_id := int(target_ids[target_index])
		var hit_position := hit_positions[target_index]
		if enemy_net_id <= 0 or seen_ids.has(enemy_net_id) or not _is_finite_vector2(hit_position):
			continue
		seen_ids[enemy_net_id] = true
		sanitized_target_ids.append(enemy_net_id)
		sanitized_hit_positions.append(hit_position)
	_active_tiyi_activations_by_peer.erase(peer_id)
	_tiyi_target_ids_by_peer.erase(peer_id)
	player_node.call(
		"play_remote_high_noon_finished",
		activation_id,
		sanitized_target_ids,
		sanitized_hit_positions
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_tiyi_high_noon_cancelled(peer_id: int, activation_id: int) -> void:
	if game == null or activation_id <= 0:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id > 0 and sender_id != _get_host_peer_id():
		return
	if int(_active_tiyi_activations_by_peer.get(peer_id, 0)) != activation_id:
		return
	_active_tiyi_activations_by_peer.erase(peer_id)
	_tiyi_target_ids_by_peer.erase(peer_id)
	var player_node := game.get_player_for_peer(peer_id)
	if _is_valid_tiyi_player(player_node):
		player_node.call("cancel_remote_high_noon", activation_id)


func _cancel_authoritative_tiyi_high_noon(
	peer_id: int,
	activation_id: int,
	broadcast_cancel: bool
) -> void:
	if not net_manager.is_host() or activation_id <= 0:
		return
	if int(_active_tiyi_activations_by_peer.get(peer_id, 0)) != activation_id:
		return
	_active_tiyi_activations_by_peer.erase(peer_id)
	_tiyi_target_ids_by_peer.erase(peer_id)
	if broadcast_cancel:
		_rpc_to_connected_clients(
			&"net_tiyi_high_noon_cancelled",
			[peer_id, activation_id]
		)


func _sanitize_tiyi_target_ids(
	target_ids: PackedInt32Array,
	require_host_enemy: bool = true
) -> PackedInt32Array:
	var sanitized_ids := PackedInt32Array()
	var seen_ids: Dictionary = {}
	for target_id_variant in target_ids:
		if sanitized_ids.size() >= TIYI_HIGH_NOON_MAX_TARGETS:
			break
		var enemy_net_id := int(target_id_variant)
		if enemy_net_id <= 0 or seen_ids.has(enemy_net_id):
			continue
		if require_host_enemy:
			var enemy := _get_host_enemy_for_net_id(enemy_net_id)
			if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
				continue
		seen_ids[enemy_net_id] = true
		sanitized_ids.append(enemy_net_id)
	return sanitized_ids


func _is_valid_tiyi_player(player_node: Player) -> bool:
	return (
		player_node != null
		and is_instance_valid(player_node)
		and player_node.has_method("is_tiyi")
		and bool(player_node.call("is_tiyi"))
	)


func _is_valid_hoe_cat_player(player_node: Player) -> bool:
	return (
		player_node != null
		and is_instance_valid(player_node)
		and player_node.has_method("is_hoe_cat")
		and bool(player_node.call("is_hoe_cat"))
	)


func _is_valid_tango_player(player_node: Player) -> bool:
	return (
		player_node != null
		and is_instance_valid(player_node)
		and player_node.has_method("is_tango")
		and bool(player_node.call("is_tango"))
		and player_node.has_method("try_authoritative_tango_charge_started")
		and player_node.has_method("try_authoritative_tango_charge_released")
		and player_node.has_method("cancel_authoritative_tango_charge")
		and player_node.has_method("is_tango_charge_active")
		and player_node.has_method("play_remote_tango_charge_started")
		and player_node.has_method("reconcile_predicted_tango_charge_started")
		and player_node.has_method("play_remote_tango_barrage_started")
		and player_node.has_method("apply_remote_tango_barrage_snapshot")
		and player_node.has_method("play_remote_tango_charge_cancelled")
		and player_node.has_method("reconcile_predicted_tango_barrage_started")
		and player_node.has_method("try_start_authoritative_electric_surge")
		and player_node.has_method("play_remote_electric_surge_started")
		and player_node.has_method("cancel_remote_electric_surge")
		and player_node.has_method("is_electric_surge_active")
	)


func _sanitize_tango_charge_direction(player_node: Player, direction: Vector2) -> Vector2:
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


func _sanitize_hoe_action_direction(player_node: Player, direction: Vector2) -> Vector2:
	if is_finite(direction.x) and is_finite(direction.y) and direction.length_squared() > 0.0001:
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
	if game == null or peer_id <= 0 or not _is_finite_vector2(target_position):
		return false
	var player_node := game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return false
	if not player_coordinator.apply_authoritative_teleport_to_player(
		player_node,
		target_position
	):
		return false
	if peer_id != game.multiplayer_local_peer_id:
		var now := _get_net_time()
		_accepted_player_state_positions[peer_id] = target_position
		_accepted_player_state_times[peer_id] = now
		player_coordinator.remember_latest_client_state(
			true,
			peer_id,
			target_position,
			Vector2.ZERO,
			player_node.get_multiplayer_facing_id(),
			player_node.get_multiplayer_anim_state()
		)
	return true


func _accept_client_player_state(
	peer_id: int,
	sequence: int,
	reported_position: Vector2,
	reported_velocity: Vector2
) -> bool:
	var last_sequence := int(_last_player_state_sequences.get(peer_id, 0))
	if sequence <= last_sequence:
		return false
	_last_player_state_sequences[peer_id] = sequence
	if not _is_finite_vector2(reported_position) or not _is_finite_vector2(reported_velocity):
		return false
	var now := _get_net_time()
	var player_node := game.get_player_for_peer(peer_id) if game != null else null
	if player_node == null or not is_instance_valid(player_node):
		return false
	if not _accepted_player_state_positions.has(peer_id):
		if (
			player_node.global_position.distance_to(reported_position)
			> PLAYER_STATE_POSITION_TOLERANCE * 4.0
		):
			return false
		_accepted_player_state_positions[peer_id] = reported_position
		_accepted_player_state_times[peer_id] = now
		return true
	var previous_position := _accepted_player_state_positions[peer_id] as Vector2
	var previous_time := float(_accepted_player_state_times.get(peer_id, now))
	var elapsed := clampf(now - previous_time, 1.0 / 120.0, PLAYER_STATE_MAX_VALIDATION_SECONDS)
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
	if movement_delta.length_squared() > 0.001 and player_node.test_move(
		player_node.global_transform,
		movement_delta
	):
		return false
	_accepted_player_state_positions[peer_id] = reported_position
	_accepted_player_state_times[peer_id] = now
	return true

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
	var active_surge_record := _active_tango_electric_surges_by_peer.get(
		owner_peer_id,
		{}
	) as Dictionary
	var charge_sequence := int(
		_tango_charge_sequences_by_peer.get(owner_peer_id, 0)
	)
	var maximum_internal_barrage_seconds := TANGO_BARRAGE_MAXIMUM_SECONDS
	if (
		not active_surge_record.is_empty()
		and charge_sequence > 0
		and int(active_surge_record.get("charge_sequence", 0))
			== charge_sequence
		and charge_ratio >= 1.0 - TANGO_CHARGE_THRESHOLD_EPSILON
	):
		maximum_internal_barrage_seconds = TANGO_ELECTRIC_SURGE_DURATION_SECONDS
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
	var current_charge_sequence := int(
		_tango_charge_sequences_by_peer.get(owner_peer_id, 0)
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
		_tango_charge_sequences_by_peer[owner_peer_id] = charge_sequence
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
		_tango_charge_sequences_by_peer[owner_peer_id] = next_charge_sequence


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


func _acquire_or_instantiate_projectile(scene: PackedScene) -> Node:
	if scene == null:
		return null
	if has_session_object_pool_scene(scene):
		return acquire_session_object(scene, false)
	return scene.instantiate()


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


func _get_enemy_burn_family(source_type: StringName) -> StringName:
	return CombatAttackRegistry.get_burn_family(source_type)


func _get_enemy_burn_level(source_type: StringName) -> int:
	return CombatAttackRegistry.get_burn_tick_damage(source_type)


func _get_enemy_burn_duration(source_type: StringName) -> float:
	return CombatAttackRegistry.get_burn_duration(source_type)


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


func _is_fire_sorcerer_fireball_contact_consumed(
	projectile_id: int,
	source_type: StringName
) -> bool:
	return projectile_coordinator.is_fire_sorcerer_fireball_contact_consumed(
		projectile_id,
		source_type
	)


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


func _get_frost_ice_spike_record_damage(
	projectile_id: int,
	source_type: StringName
) -> int:
	return projectile_coordinator.get_frost_ice_spike_record_damage(
		projectile_id,
		source_type
	)


func _is_frost_ice_spike_contact_consumed(
	projectile_id: int,
	source_type: StringName
) -> bool:
	return projectile_coordinator.is_frost_ice_spike_contact_consumed(
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
		_accepted_player_state_positions.get(owner_peer_id),
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


func _is_valid_bamboo_mortar_visual_payload(
	plant_net_ids: PackedInt32Array,
	action_ids: PackedInt32Array,
	stages: PackedByteArray,
	spawn_positions: PackedVector2Array,
	landing_positions: PackedVector2Array,
	committed_windup_durations: PackedFloat32Array,
	host_action_times: PackedFloat64Array
) -> bool:
	var record_count := plant_net_ids.size()
	if (
		record_count <= 0
		or record_count > BAMBOO_MORTAR_VISUAL_MAX_RECORDS_PER_PACKET
		or action_ids.size() != record_count
		or stages.size() != record_count
		or spawn_positions.size() != record_count
		or landing_positions.size() != record_count
		or committed_windup_durations.size() != record_count
		or host_action_times.size() != record_count
	):
		return false
	for record_index in range(record_count):
		if (
			plant_net_ids[record_index] <= 0
			or action_ids[record_index] <= 0
			or stages[record_index] > 1
			or not _is_finite_vector2(
				spawn_positions[record_index]
			)
			or not _is_finite_vector2(
				landing_positions[record_index]
			)
			or not is_finite(committed_windup_durations[record_index])
			or committed_windup_durations[record_index]
				< BAMBOO_MORTAR_SCRIPT.MIN_COMMITTED_WINDUP_DURATION_SECONDS
			or committed_windup_durations[record_index]
				> BAMBOO_MORTAR_SCRIPT.WINDUP_DURATION_SECONDS
			or not is_finite(host_action_times[record_index])
			or host_action_times[record_index] < 0.0
		):
			return false
	return true


func _is_valid_corn_machine_gun_burst_payload(
	plant_net_ids: PackedInt32Array,
	action_ids: PackedInt32Array,
	directions: PackedVector2Array,
	host_action_times: PackedFloat64Array
) -> bool:
	var record_count := plant_net_ids.size()
	if (
		record_count <= 0
		or record_count > CORN_MACHINE_GUN_BURST_MAX_RECORDS_PER_PACKET
		or action_ids.size() != record_count
		or directions.size() != record_count
		or host_action_times.size() != record_count
	):
		return false
	for record_index in range(record_count):
		var direction := directions[record_index]
		var host_action_time := host_action_times[record_index]
		if (
			plant_net_ids[record_index] <= 0
			or action_ids[record_index] <= 0
			or not _is_finite_vector2(direction)
			or direction.length_squared() <= 0.001
			or not is_finite(host_action_time)
			or host_action_time < 0.0
		):
			return false
	return true


func _prune_projectile_records(now: float) -> void:
	projectile_coordinator.prune_records(now)


func _update_recent_event_cache_prune(delta: float) -> void:
	_recent_event_prune_time_left = maxf(_recent_event_prune_time_left - delta, 0.0)
	if _recent_event_prune_time_left > 0.0:
		return
	_recent_event_prune_time_left = RECENT_EVENT_PRUNE_INTERVAL_SECONDS
	_prune_recent_event_caches(_get_net_time())


func _prune_recent_event_caches(now: float) -> void:
	_prune_recent_event_cache(_processed_player_hit_ids, now)
	_prune_recent_event_cache(_processed_collectible_effect_event_ids, now)
	_prune_projectile_records(now)


func _prune_recent_event_cache(cache: Dictionary, now: float) -> void:
	var expired_keys: Array = []
	for key in cache:
		if float(cache[key]) <= now:
			expired_keys.append(key)
	for key in expired_keys:
		cache.erase(key)


func _is_recent_event_cached(cache: Dictionary, key: Variant, now: float) -> bool:
	var expires_at_variant: Variant = cache.get(key)
	if expires_at_variant == null:
		return false
	var expires_at := float(expires_at_variant)
	if expires_at > now:
		return true
	cache.erase(key)
	return false


func _remember_recent_event(
	cache: Dictionary,
	key: Variant,
	retention_seconds: float,
	now: float
) -> void:
	cache[key] = now + retention_seconds


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


func _apply_confirmed_enemy_damage_batch(
	enemy_net_id: int,
	enemy: Enemy,
	damage_amounts: PackedInt64Array,
	hit_counts: PackedInt32Array,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	show_hit_particles: bool = true
) -> bool:
	if (
		enemy_net_id <= 0
		or enemy == null
		or not is_instance_valid(enemy)
	):
		return false
	var request := DamageBatchRequest.new(
		damage_amounts,
		hit_counts,
		int(damage_type)
	)
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
		# event containing this final confirmed batch.
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
	_bamboo_mortar_visual_flush_time_left -= maxf(delta, 0.0)
	if _bamboo_mortar_visual_flush_time_left <= 0.0:
		_bamboo_mortar_visual_flush_time_left = (
			BAMBOO_MORTAR_VISUAL_FLUSH_INTERVAL_SECONDS
		)
		_flush_bamboo_mortar_visuals()
	_corn_machine_gun_burst_flush_time_left -= maxf(delta, 0.0)
	if _corn_machine_gun_burst_flush_time_left <= 0.0:
		_corn_machine_gun_burst_flush_time_left = (
			CORN_MACHINE_GUN_BURST_FLUSH_INTERVAL_SECONDS
		)
		_flush_corn_machine_gun_burst_visuals()
	_plant_health_flush_time_left -= maxf(delta, 0.0)
	if _plant_health_flush_time_left <= 0.0:
		_plant_health_flush_time_left = PLANT_HEALTH_FLUSH_INTERVAL_SECONDS
		_flush_plant_health_updates()
	if world_flow_coordinator.update_host(delta):
		_flush_tiyi_target_updates()


func _flush_bamboo_mortar_visuals() -> void:
	if _pending_bamboo_mortar_visuals.is_empty():
		return
	assert(
		_pending_bamboo_mortar_action_ids.size()
		== _pending_bamboo_mortar_visuals.size()
		and _pending_bamboo_mortar_stages.size()
		== _pending_bamboo_mortar_visuals.size()
		and _pending_bamboo_mortar_spawn_positions.size()
		== _pending_bamboo_mortar_visuals.size()
		and _pending_bamboo_mortar_landing_positions.size()
		== _pending_bamboo_mortar_visuals.size()
		and _pending_bamboo_mortar_windup_durations.size()
		== _pending_bamboo_mortar_visuals.size()
		and _pending_bamboo_mortar_host_times.size()
		== _pending_bamboo_mortar_visuals.size()
	)
	for chunk_start in range(
		0,
		_pending_bamboo_mortar_visuals.size(),
		BAMBOO_MORTAR_VISUAL_MAX_RECORDS_PER_PACKET
	):
		var chunk_end := mini(
			chunk_start + BAMBOO_MORTAR_VISUAL_MAX_RECORDS_PER_PACKET,
			_pending_bamboo_mortar_visuals.size()
		)
		_rpc_to_connected_clients(
			&"net_bamboo_mortar_visual_batch",
			[
				_pending_bamboo_mortar_visuals.slice(
					chunk_start,
					chunk_end
				),
				_pending_bamboo_mortar_action_ids.slice(
					chunk_start,
					chunk_end
				),
				_pending_bamboo_mortar_stages.slice(
					chunk_start,
					chunk_end
				),
				_pending_bamboo_mortar_spawn_positions.slice(
					chunk_start,
					chunk_end
				),
				_pending_bamboo_mortar_landing_positions.slice(
					chunk_start,
					chunk_end
				),
				_pending_bamboo_mortar_windup_durations.slice(
					chunk_start,
					chunk_end
				),
				_pending_bamboo_mortar_host_times.slice(
					chunk_start,
					chunk_end
				),
			]
		)
	_clear_bamboo_mortar_visuals()


func _flush_corn_machine_gun_burst_visuals() -> void:
	if _pending_corn_machine_gun_burst_visuals.is_empty():
		return
	assert(
		_pending_corn_machine_gun_burst_action_ids.size()
		== _pending_corn_machine_gun_burst_visuals.size()
		and _pending_corn_machine_gun_burst_directions.size()
		== _pending_corn_machine_gun_burst_visuals.size()
		and _pending_corn_machine_gun_burst_host_times.size()
		== _pending_corn_machine_gun_burst_visuals.size()
	)
	for chunk_start in range(
		0,
		_pending_corn_machine_gun_burst_visuals.size(),
		CORN_MACHINE_GUN_BURST_MAX_RECORDS_PER_PACKET
	):
		var chunk_end := mini(
			chunk_start + CORN_MACHINE_GUN_BURST_MAX_RECORDS_PER_PACKET,
			_pending_corn_machine_gun_burst_visuals.size()
		)
		var plant_net_ids := _pending_corn_machine_gun_burst_visuals.slice(
			chunk_start,
			chunk_end
		)
		var action_ids := _pending_corn_machine_gun_burst_action_ids.slice(
			chunk_start,
			chunk_end
		)
		var directions := _pending_corn_machine_gun_burst_directions.slice(
			chunk_start,
			chunk_end
		)
		var host_action_times := _pending_corn_machine_gun_burst_host_times.slice(
			chunk_start,
			chunk_end
		)
		_rpc_to_connected_clients(
			&"net_corn_machine_gun_burst_batch",
			[plant_net_ids, action_ids, directions, host_action_times]
		)
	_clear_corn_machine_gun_burst_visuals()


func _flush_tiyi_target_updates() -> void:
	if _pending_tiyi_target_updates.is_empty():
		return
	for peer_id_variant in _pending_tiyi_target_updates.keys():
		var peer_id := int(peer_id_variant)
		var update := _pending_tiyi_target_updates.get(peer_id, {}) as Dictionary
		_rpc_to_connected_clients(
			&"net_tiyi_high_noon_targets",
			[
				peer_id,
				int(update.get("activation_id", 0)),
				update.get("target_ids", PackedInt32Array()) as PackedInt32Array,
			]
		)
	_pending_tiyi_target_updates.clear()


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


func _flush_plant_health_updates() -> void:
	if not _has_tower_mode() or _pending_plant_health_updates.is_empty():
		return
	var net_ids: Array[int] = []
	for net_id_variant in _pending_plant_health_updates.keys():
		var net_id := int(net_id_variant)
		if not _NetConstants.is_valid_network_combat_value(net_id):
			push_error("MpGame: 拒绝序列化越界植物 net_id。")
			_pending_plant_health_updates.erase(net_id_variant)
			continue
		net_ids.append(net_id)
	net_ids.sort()
	_send_pending_plant_health_updates(net_ids)
	for net_id in net_ids:
		_pending_plant_health_updates.erase(net_id)


func _send_pending_plant_health_updates(net_ids: Array[int]) -> void:
	for chunk_start in range(0, net_ids.size(), PLANT_HEALTH_MAX_RECORDS_PER_PACKET):
		var chunk_end := mini(
			chunk_start + PLANT_HEALTH_MAX_RECORDS_PER_PACKET,
			net_ids.size()
		)
		var chunk_ids := PackedInt32Array()
		var health_values := PackedInt32Array()
		var maximum_values := PackedInt32Array()
		var revisions := PackedInt32Array()
		var damage_values := PackedInt32Array()
		var healing_values := PackedInt32Array()
		var directions := PackedVector2Array()
		var damage_types := PackedByteArray()
		var world_positions := PackedVector2Array()
		for record_index in range(chunk_start, chunk_end):
			var net_id := net_ids[record_index]
			var update := _pending_plant_health_updates.get(net_id, {}) as Dictionary
			if update.is_empty():
				continue
			var current_health := int(update.get("current_health", 0))
			var maximum_health := int(update.get("maximum_health", 1))
			var health_revision := int(update.get("health_revision", 0))
			var applied_damage := int(update.get("damage", 0))
			var applied_healing := int(update.get("healing", 0))
			if (
				not _NetConstants.is_valid_network_combat_value(net_id)
				or not _NetConstants.is_valid_network_combat_value(current_health)
				or not _NetConstants.is_valid_network_combat_value(maximum_health)
				or not _NetConstants.is_valid_network_combat_value(health_revision)
				or not _NetConstants.is_valid_network_combat_value(applied_damage)
				or not _NetConstants.is_valid_network_combat_value(applied_healing)
			):
				push_error("MpGame: 拒绝序列化越界植物战斗值。")
				continue
			chunk_ids.append(net_id)
			health_values.append(current_health)
			maximum_values.append(maximum_health)
			revisions.append(health_revision)
			damage_values.append(applied_damage)
			healing_values.append(applied_healing)
			directions.append(update.get("impact_direction", Vector2.ZERO) as Vector2)
			damage_types.append(int(update.get("damage_type", EnemyConfig.DamageType.PHYSICAL)))
			world_positions.append(update.get("world_position", Vector2.ZERO) as Vector2)
		if chunk_ids.is_empty():
			continue
		_rpc_to_connected_clients(
			&"net_plant_health_batch",
			[
				chunk_ids,
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
	if not _has_tower_mode() or game == null or net_manager.is_host():
		return
	var record_count := mini(
		net_ids.size(),
		mini(
			health_values.size(),
			mini(
				maximum_values.size(),
				mini(
					revisions.size(),
					mini(
						damage_values.size(),
						mini(
							healing_values.size(),
							mini(
								directions.size(),
								mini(damage_types.size(), world_positions.size())
							)
						)
					)
				)
			)
		)
	)
	for record_index in range(record_count):
		var net_id := net_ids[record_index]
		var health_revision := revisions[record_index]
		if (
			net_id <= 0
			or not _NetConstants.is_valid_network_combat_value(
				health_values[record_index]
			)
			or not _NetConstants.is_valid_network_combat_value(
				maximum_values[record_index]
			)
			or not _NetConstants.is_valid_network_combat_value(health_revision)
			or not _NetConstants.is_valid_network_combat_value(
				damage_values[record_index]
			)
			or not _NetConstants.is_valid_network_combat_value(
				healing_values[record_index]
			)
		):
			continue
		var live_plant_before := _get_tower_plant(net_id)
		var stale_for_live_plant := (
			live_plant_before != null
			and is_instance_valid(live_plant_before)
			and health_revision <= live_plant_before.health_revision
		)
		_apply_or_defer_remote_plant_health(
			net_id,
			health_values[record_index],
			maximum_values[record_index],
			health_revision
		)
		var applied_damage := damage_values[record_index]
		var applied_healing := healing_values[record_index]
		if applied_damage <= 0 and applied_healing <= 0:
			continue
		if not _accept_remote_plant_feedback_revision(net_id, health_revision):
			continue
		# A reliable roster/repair can overtake CH7. Do not replay historical
		# feedback against an already-newer live replica; removed replicas remain
		# eligible because the packet carries the impact world position.
		if stale_for_live_plant:
			continue
		if applied_damage > 0:
			game.show_combat_number(
				applied_damage,
				world_positions[record_index],
				DamageNumberPool.CombatNumberKind.DAMAGE,
				directions[record_index],
				int(damage_types[record_index]) as EnemyConfig.DamageType,
				DamageNumberPool.DisplayPriority.IMPORTANT
			)
		if applied_healing > 0:
			game.show_combat_number(
				applied_healing,
				world_positions[record_index],
				DamageNumberPool.CombatNumberKind.HEALING,
				Vector2.ZERO,
				EnemyConfig.DamageType.PHYSICAL,
				DamageNumberPool.DisplayPriority.IMPORTANT
			)


func _apply_or_defer_remote_plant_health(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	if (
		not _has_tower_mode()
		or game == null
		or net_manager.is_host()
		or net_id <= 0
		or health_revision < 0
		or _removed_remote_plant_ids.has(net_id)
	):
		return
	var plant := _get_tower_plant(net_id)
	if plant == null or not is_instance_valid(plant):
		_cache_remote_plant_health(
			net_id,
			current_health,
			maximum_health,
			health_revision
		)
		return

	var pending := _pending_remote_plant_health_updates.get(net_id, {}) as Dictionary
	var selected_health := current_health
	var selected_maximum := maximum_health
	var selected_revision := health_revision
	if int(pending.get("health_revision", -1)) >= health_revision:
		selected_health = int(pending.get("current_health", current_health))
		selected_maximum = int(pending.get("maximum_health", maximum_health))
		selected_revision = int(pending.get("health_revision", health_revision))
	_erase_pending_remote_plant_health(net_id)
	tower_mode_adapter.apply_remote_plant_health(
		net_id,
		selected_health,
		selected_maximum,
		selected_revision
	)


func _cache_remote_plant_health(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	var previous := _pending_remote_plant_health_updates.get(net_id, {}) as Dictionary
	if int(previous.get("health_revision", -1)) >= health_revision:
		return
	if previous.is_empty():
		while (
			_pending_remote_plant_health_updates.size()
			>= CLIENT_PENDING_PLANT_HEALTH_MAX_ENTRIES
			and not _pending_remote_plant_health_order.is_empty()
		):
			var evicted_net_id := int(_pending_remote_plant_health_order.pop_front())
			_pending_remote_plant_health_updates.erase(evicted_net_id)
		_pending_remote_plant_health_order.append(net_id)
	_pending_remote_plant_health_updates[net_id] = {
		"current_health": current_health,
		"maximum_health": maximum_health,
		"health_revision": health_revision,
	}


func _apply_pending_remote_plant_health(net_id: int) -> void:
	if not _has_tower_mode():
		return
	var pending := _pending_remote_plant_health_updates.get(net_id, {}) as Dictionary
	if pending.is_empty():
		return
	var plant := _get_tower_plant(net_id)
	if plant == null or not is_instance_valid(plant):
		return
	_erase_pending_remote_plant_health(net_id)
	tower_mode_adapter.apply_remote_plant_health(
		net_id,
		int(pending.get("current_health", 0)),
		int(pending.get("maximum_health", 1)),
		int(pending.get("health_revision", -1))
	)


func _erase_pending_remote_plant_health(net_id: int) -> void:
	if not _pending_remote_plant_health_updates.erase(net_id):
		return
	_pending_remote_plant_health_order.erase(net_id)


func _mark_remote_plant_removed(net_id: int) -> void:
	if net_id <= 0:
		return
	tower_economy_coordinator.notify_plant_removed(net_id)
	_erase_pending_remote_plant_health(net_id)
	if _removed_remote_plant_ids.has(net_id):
		return
	while (
		_removed_remote_plant_ids.size()
		>= CLIENT_REMOVED_PLANT_TOMBSTONE_MAX_ENTRIES
		and not _removed_remote_plant_id_order.is_empty()
	):
		var evicted_net_id := int(_removed_remote_plant_id_order.pop_front())
		_removed_remote_plant_ids.erase(evicted_net_id)
	_removed_remote_plant_ids[net_id] = true
	_removed_remote_plant_id_order.append(net_id)


func _clear_remote_plant_removed_marker(net_id: int) -> void:
	if net_id <= 0:
		return
	tower_economy_coordinator.notify_plant_available(net_id)
	if not _removed_remote_plant_ids.erase(net_id):
		return
	_removed_remote_plant_id_order.erase(net_id)


func _accept_remote_plant_feedback_revision(net_id: int, health_revision: int) -> bool:
	if net_id <= 0 or health_revision < 0:
		return false
	if health_revision <= int(_remote_plant_feedback_revisions.get(net_id, -1)):
		return false
	if not _remote_plant_feedback_revisions.has(net_id):
		while (
			_remote_plant_feedback_revisions.size()
			>= CLIENT_REMOVED_PLANT_TOMBSTONE_MAX_ENTRIES
			and not _remote_plant_feedback_revision_order.is_empty()
		):
			var evicted_net_id := int(_remote_plant_feedback_revision_order.pop_front())
			_remote_plant_feedback_revisions.erase(evicted_net_id)
		_remote_plant_feedback_revision_order.append(net_id)
	_remote_plant_feedback_revisions[net_id] = health_revision
	return true


func _clear_remote_plant_health_state() -> void:
	_pending_remote_plant_health_updates.clear()
	_pending_remote_plant_health_order.clear()
	_removed_remote_plant_ids.clear()
	_removed_remote_plant_id_order.clear()
	_remote_plant_feedback_revisions.clear()
	_remote_plant_feedback_revision_order.clear()


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
	if source_id <= 0 or target_peer_id <= 0 or damage <= 0:
		return false
	# This Variant adapter is retained only for existing enemy/projectile call
	# sites. It normalizes immediately into one typed DamageRequest below.
	var resolved_damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
	var source_direction := Vector2.ZERO
	var resolved_is_ranged := is_ranged
	if damage_type_or_source_direction is Vector2:
		source_direction = damage_type_or_source_direction as Vector2
		if source_direction_or_is_ranged is bool:
			resolved_is_ranged = bool(source_direction_or_is_ranged)
	elif damage_type_or_source_direction is int:
		resolved_damage_type = int(damage_type_or_source_direction) as EnemyConfig.DamageType
		if source_direction_or_is_ranged is Vector2:
			source_direction = source_direction_or_is_ranged as Vector2
		elif source_direction_or_is_ranged is bool:
			resolved_is_ranged = bool(source_direction_or_is_ranged)
	var is_frost_ice_spike := source_type == FROST_SORCERER_ICE_SPIKE_TYPE
	var is_fire_slime_touch := source_type == FIRE_SLIME_TOUCH_TYPE
	var is_frost_slime_touch := source_type == FROST_SLIME_TOUCH_TYPE
	if is_frost_ice_spike:
		var authoritative_damage := _get_frost_ice_spike_record_damage(
			source_id,
			source_type
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
	var player_node: Player = null
	if game != null:
		player_node = game.get_player_for_peer(target_peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return false
	if _is_recent_event_cached(_processed_player_hit_ids, hit_key, now):
		return true
	var fire_source_bit := _get_fire_sorcerer_fireball_source_bit(source_type)
	var contact_was_consumed := false
	if fire_source_bit != 0:
		contact_was_consumed = (
			_is_fire_sorcerer_fireball_contact_consumed(source_id, source_type)
			if contact_preconsumed
			else try_consume_fire_sorcerer_fireball_contact(
				source_id,
				source_type
			)
		)
		if not contact_was_consumed:
			return true
	elif is_frost_ice_spike:
		contact_was_consumed = (
			_is_frost_ice_spike_contact_consumed(source_id, source_type)
			if contact_preconsumed
			else try_consume_frost_sorcerer_ice_spike_contact(
				source_id,
				source_type
			)
		)
		if not contact_was_consumed:
			return true
	if net_manager.is_client():
		if target_peer_id != _get_local_peer_id():
			return true
		if player_node.is_dead:
			return true
		# Client contact only retires the local projectile presentation and its
		# duplicate key. It must not enter Player's stateful sink: a false-positive
		# local collision could otherwise trigger death/spectator lifecycle before
		# the Host rejects the hit. Reliable Host results own health and feedback.
		_remember_recent_event(
			_processed_player_hit_ids,
			hit_key,
			HIT_DEDUP_RETENTION_SECONDS,
			now
		)
		return true
	if net_manager.is_host():
		if player_node.is_dead:
			return true
		_apply_player_hit_report(
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
	var trusted_family := _get_enemy_burn_family(source_family)
	var trusted_burn_level := _get_enemy_burn_level(trusted_family)
	if trusted_family == &"" or trusted_burn_level <= 0:
		return false
	return request_multiplayer_player_damage_over_time_tick(
		player_peer_id,
		&"burn",
		trusted_family,
		trusted_burn_level
	)


## Host-only sink used by authoritative Player status schedulers. This is a
## local method, not an RPC: clients cannot submit arbitrary periodic damage.
func request_multiplayer_player_damage_over_time_tick(
	player_peer_id: int,
	status_id: StringName,
	source_family: StringName,
	tick_damage: int
) -> bool:
	if (
		net_manager == null
		or not net_manager.is_host()
		or game == null
		or player_peer_id <= 0
		or source_family == &""
		or tick_damage <= 0
	):
		return false
	var damage_type := EnemyConfig.DamageType.PHYSICAL
	match status_id:
		&"burn":
			var trusted_family := _get_enemy_burn_family(source_family)
			var trusted_burn_level := _get_enemy_burn_level(trusted_family)
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
	var player_node := game.get_player_for_peer(player_peer_id)
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
	if confirmed_dead and _is_valid_tiyi_player(player_node):
		_clear_projectiles_for_peer(player_peer_id)
		_clear_projectile_records_for_peer(player_peer_id)
	var health_revision := _next_player_health_revision(player_peer_id)
	if confirmed_dead:
		_schedule_player_revive(player_peer_id)
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
	_rpc_to_connected_clients(
		&"net_player_damage_applied",
		event_arguments
	)
	net_player_damage_applied(
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


## Host-only replication path for Luoxi's explicit HP-loss card effects.
## The Player method deliberately bypasses ordinary combat mitigation; this
## wrapper only publishes the already-applied authoritative health result.
func apply_luoxi_direct_health_loss(
	target_player: Player,
	amount: int,
	minimum_health: int = 0
) -> int:
	if (
		net_manager == null
		or not net_manager.is_host()
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
	if confirmed_dead and _is_valid_tiyi_player(target_player):
		_clear_projectiles_for_peer(target_player.peer_id)
		_clear_projectile_records_for_peer(target_player.peer_id)
	var health_revision := _next_player_health_revision(target_player.peer_id)
	if confirmed_dead:
		_schedule_player_revive(target_player.peer_id)
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
	_rpc_to_connected_clients(
		&"net_player_damage_applied",
		event_arguments
	)
	net_player_damage_applied(
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


func request_player_hit_report(
	_source_id: int,
	_player_peer_id: int,
	_source_type: StringName,
	_impact_direction: Vector2,
	_damage_flags: int
) -> void:
	# Protocol-v25 compatibility shell. Client hit claims are intentionally
	# disabled: every eligible attack already has a live Host simulation, and a
	# proximity-only client hint is not proof of collision.
	return


@rpc("any_peer", "call_remote", "reliable", 5)
func _rpc_player_hit_report(
	_source_id: int,
	_player_peer_id: int,
	_attack_wire_id: int,
	_impact_direction: Vector2,
	_damage_flags: int
) -> void:
	# Fail closed for old or malicious clients. Host collision callbacks enter
	# the canonical local sink directly and never pass through this RPC.
	return


func _apply_player_hit_report(
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
	if source_id <= 0 or player_peer_id <= 0:
		return DamageResult.rejected(
			request,
			CombatTypes.DamageRejectionReason.INVALID_REQUEST
		)
	var player_node: Player = null
	if game != null:
		player_node = game.get_player_for_peer(player_peer_id)
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
		var authoritative_damage := _get_frost_ice_spike_record_damage(
			source_id,
			source_type
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
	if _is_recent_event_cached(_processed_player_hit_ids, hit_key, now):
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
			_is_fire_sorcerer_fireball_contact_consumed(
				source_id,
				source_type
			)
			if contact_preconsumed
			else try_consume_fire_sorcerer_fireball_contact(
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
			_is_frost_ice_spike_contact_consumed(source_id, source_type)
			if contact_preconsumed
			else try_consume_frost_sorcerer_ice_spike_contact(
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
	_remember_recent_event(_processed_player_hit_ids, hit_key, HIT_DEDUP_RETENTION_SECONDS, now)
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
	if result.accepted and confirmed_damage > 0 and not confirmed_dead:
		var burn_family := _get_enemy_burn_family(source_type)
		var burn_level := _get_enemy_burn_level(burn_family)
		if burn_family != &"" and burn_level > 0:
			player_node.apply_burn_status(
				burn_family,
				_get_enemy_burn_duration(burn_family),
				burn_level
			)
		if CombatAttackRegistry.applies_cold(source_type):
			confirmed_cold_applied = player_node.apply_cold_status()
	_show_confirmed_player_damage_number(
		player_node,
		confirmed_damage,
		confirmed_impact_direction,
		confirmed_damage_type
	)
	if confirmed_dead and _is_valid_tiyi_player(player_node):
		_clear_projectiles_for_peer(player_peer_id)
		_clear_projectile_records_for_peer(player_peer_id)
	var health_revision := _next_player_health_revision(player_peer_id)
	if confirmed_dead:
		_schedule_player_revive(player_peer_id)
	if (
		not _NetConstants.is_valid_network_combat_value(result.health_after)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
		or not _NetConstants.is_valid_network_combat_value(confirmed_damage)
	):
		push_error("MpGame: 玩家伤害结果超出网络 signed int32 契约，已拒绝发送。")
		return result
	_rpc_to_connected_clients(
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
		]
	)
	net_player_damage_applied(
		player_peer_id,
		result.health_after,
		confirmed_dead,
		health_revision,
		confirmed_damage,
		confirmed_impact_direction,
		int(confirmed_damage_type),
		result.accepted and not confirmed_dead,
		confirmed_cold_applied,
		result.rejection_reason
	)
	return result


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
	if (
		player_peer_id <= 0
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
		or not _NetConstants.is_valid_network_combat_value(confirmed_damage)
	):
		return
	var player_node: Player = null
	if game != null:
		player_node = game.get_player_for_peer(player_peer_id)
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
		and net_manager != null
		and net_manager.is_client()
	):
		player_node.play_confirmed_dodge_feedback()
	if apply_confirmed_cold and confirmed_damage > 0 and not is_dead:
		player_node.apply_cold_status()
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
	if is_dead and applied_life_state and _is_valid_tiyi_player(player_node):
		_active_tiyi_activations_by_peer.erase(player_peer_id)
		_tiyi_target_ids_by_peer.erase(player_peer_id)
		_clear_projectiles_for_peer(player_peer_id)
		_clear_projectile_records_for_peer(player_peer_id)
	if (
		grant_hit_invincibility
		and applied_life_state
		and is_client_view_runtime()
		and player_peer_id == _get_client_view_local_peer_id()
		and not player_node.is_dead
		and player_node.current_health < player_node.max_health
	):
		player_node.start_multiplayer_invincibility(player_node.invincibility_duration)


func _show_confirmed_player_damage_number(
	player_node: Player,
	confirmed_damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> void:
	if (
		game == null
		or player_node == null
		or not is_instance_valid(player_node)
		or confirmed_damage <= 0
	):
		return
	game.show_damage_number(
		confirmed_damage,
		player_node.global_position,
		impact_direction,
		damage_type,
		DamageNumberPool.DisplayPriority.IMPORTANT
	)


func apply_multiplayer_player_heal(target_player: Player, heal_amount: int) -> bool:
	if not net_manager.is_host():
		return false
	if target_player == null or not is_instance_valid(target_player):
		return false
	if heal_amount <= 0 or target_player.peer_id <= 0:
		return false
	if not target_player._try_heal(heal_amount, false):
		return false
	report_multiplayer_player_healing(
		target_player,
		target_player.last_healing_received
	)
	return true


## Receives an already-applied authoritative heal. Keeping replication here
## makes every Host-side source (pickup, leech, trigger, aura or future skill)
## share one revisioned confirmation path without health_changed inference.
func report_multiplayer_player_healing(
	target_player: Player,
	confirmed_healing: int
) -> void:
	if not net_manager.is_host():
		return
	if target_player == null or not is_instance_valid(target_player):
		return
	if confirmed_healing <= 0 or target_player.peer_id <= 0 or target_player.is_dead:
		return
	var health_revision := _next_player_health_revision(target_player.peer_id)
	if (
		not _NetConstants.is_valid_network_combat_value(target_player.current_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
		or not _NetConstants.is_valid_network_combat_value(confirmed_healing)
	):
		push_error("MpGame: 玩家治疗结果超出网络 signed int32 契约，已拒绝发送。")
		return
	target_player.queue_healing_number(confirmed_healing)
	_rpc_to_connected_clients(
		&"net_player_healed",
		[
			target_player.peer_id,
			target_player.current_health,
			health_revision,
			confirmed_healing,
		]
	)


func apply_multiplayer_collectible_player_heal(target_player: Player, heal_amount: int) -> bool:
	return apply_multiplayer_player_heal(target_player, heal_amount)


@rpc("authority", "call_remote", "reliable", 5)
func net_player_healed(
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
	):
		return
	var player_node: Player = null
	if game != null:
		player_node = game.get_player_for_peer(peer_id)
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
	return apply_multiplayer_player_heal(target_player, heal_amount)


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

func _next_player_health_revision(peer_id: int) -> int:
	var next_revision := int(_player_health_revisions.get(peer_id, 0)) + 1
	_player_health_revisions[peer_id] = next_revision
	_mark_player_health_revision_applied(peer_id, next_revision)
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
		or health_revision < player_coordinator.get_applied_health_revision(peer_id)
	):
		return false
	player_node.set_multiplayer_health_state(current_health, is_dead)
	_mark_player_health_revision_applied(peer_id, health_revision)
	return true


func _mark_player_health_revision_applied(peer_id: int, health_revision: int) -> void:
	player_coordinator.mark_health_revision_applied(peer_id, health_revision)


func _schedule_player_revive(peer_id: int) -> void:
	if peer_id <= 0:
		return
	if _active_tango_charges_by_peer.has(peer_id):
		_cancel_authoritative_tango_charge(peer_id, true)
	if (
		game == null
		or _mode_adapter == null
		or not _mode_adapter.allows_player_respawn(peer_id)
		or _dead_player_revive_times.has(peer_id)
		or _mode_adapter.is_terminal_combat_state()
	):
		return
	player_coordinator.erase_latest_client_state(peer_id)
	var revive_delay := _mode_adapter.consume_next_player_respawn_delay(peer_id)
	revive_delay = maxf(revive_delay, 0.0)
	_dead_player_revive_times[peer_id] = _get_net_time() + revive_delay
	_dead_player_revive_last_seconds[peer_id] = -1
	_rpc_to_connected_clients(
		&"net_player_revive_countdown",
		[peer_id, int(ceil(revive_delay))]
	)
	net_player_revive_countdown(peer_id, int(ceil(revive_delay)))


func _host_update_player_revives() -> void:
	if not net_manager.is_host() or game == null:
		return
	if _mode_adapter == null or _mode_adapter.is_terminal_combat_state():
		return
	var now := _get_net_time()
	var due_peers: Array[int] = []
	var disallowed_peers: Array[int] = []
	for peer_id_variant in _dead_player_revive_times:
		var peer_id := int(peer_id_variant)
		if _mode_adapter == null or not _mode_adapter.allows_player_respawn(peer_id):
			disallowed_peers.append(peer_id)
			continue
		var revive_at := float(_dead_player_revive_times[peer_id])
		var seconds_left := maxi(ceili(revive_at - now), 0)
		if seconds_left != int(_dead_player_revive_last_seconds.get(peer_id, -1)):
			_dead_player_revive_last_seconds[peer_id] = seconds_left
			_rpc_to_connected_clients(&"net_player_revive_countdown", [peer_id, seconds_left])
			net_player_revive_countdown(peer_id, seconds_left)
		if now >= revive_at:
			due_peers.append(peer_id)
	for peer_id in disallowed_peers:
		_dead_player_revive_times.erase(peer_id)
		_dead_player_revive_last_seconds.erase(peer_id)
		if _mode_adapter != null:
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


func _collect_living_player_revive_positions() -> Array[Vector2]:
	var positions: Array[Vector2] = []
	if game == null:
		return positions
	for peer_id_variant in game.peer_players:
		var peer_id := int(peer_id_variant)
		var player_node := game.peer_players[peer_id_variant] as Player
		if player_node == null or not is_instance_valid(player_node) or player_node.is_dead:
			continue
		positions.append(_get_multiplayer_player_revive_anchor_position(peer_id, player_node))
	return positions


func _get_multiplayer_player_revive_anchor_position(peer_id: int, player_node: Player) -> Vector2:
	if peer_id != _get_host_peer_id() and _accepted_player_state_positions.has(peer_id):
		return _accepted_player_state_positions[peer_id] as Vector2
	return player_node.global_position


func _pick_multiplayer_revive_position(revive_positions: Array) -> Vector2:
	if revive_positions.is_empty():
		return Vector2.ZERO
	return revive_positions[_revive_random_generator.randi_range(0, revive_positions.size() - 1)]


func _resolve_multiplayer_revive_position(
	peer_id: int,
	living_player_positions: Array
) -> Variant:
	if (
		game == null
		or peer_id <= 0
		or _mode_adapter == null
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


func _revive_player_peer(peer_id: int, revive_position: Vector2) -> void:
	if (
		game == null
		or peer_id <= 0
		or _mode_adapter == null
		or not _mode_adapter.allows_player_respawn(peer_id)
	):
		_dead_player_revive_times.erase(peer_id)
		_dead_player_revive_last_seconds.erase(peer_id)
		if _mode_adapter != null:
			_mode_adapter.clear_player_respawn_countdown(peer_id)
		return
	var player_node: Player = null
	player_node = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	var active_tiyi_activation_id := int(_active_tiyi_activations_by_peer.get(peer_id, 0))
	if active_tiyi_activation_id > 0:
		_cancel_authoritative_tiyi_high_noon(peer_id, active_tiyi_activation_id, true)
	if _active_tango_charges_by_peer.has(peer_id):
		_cancel_authoritative_tango_charge(peer_id, true)
	_dead_player_revive_times.erase(peer_id)
	_dead_player_revive_last_seconds.erase(peer_id)
	var now: float = _get_net_time()
	_accepted_player_state_positions[peer_id] = revive_position
	_accepted_player_state_times[peer_id] = now
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
		push_error("MpGame: 玩家复活生命值超出网络 signed int32 契约，已拒绝发送。")
		return
	if peer_id != _get_host_peer_id():
		player_coordinator.remember_latest_client_state(
			true,
			peer_id,
			revive_position,
			Vector2.ZERO,
			player_node.get_multiplayer_facing_id(),
			player_node.get_multiplayer_anim_state()
		)
	if peer_id != _get_host_peer_id():
		net_player_state_corrected.rpc_id(peer_id, revive_position, Vector2.ZERO)
	_rpc_to_connected_clients(
		&"net_player_revived",
		[
			peer_id,
			revive_position,
			player_node.current_health,
			PLAYER_REVIVE_INVINCIBILITY_SECONDS,
			health_revision,
		]
	)
	net_player_revived(
		peer_id,
		revive_position,
		player_node.current_health,
		PLAYER_REVIVE_INVINCIBILITY_SECONDS,
		health_revision
	)


func _on_host_revive_all_requested() -> void:
	if not net_manager.is_host() or game == null:
		return
	_clear_pending_player_revives()
	var revive_positions := _collect_living_player_revive_positions()
	for peer_id_variant in game.peer_players:
		var peer_id := int(peer_id_variant)
		if _mode_adapter == null or not _mode_adapter.allows_player_respawn(peer_id):
			continue
		var player_node := game.peer_players[peer_id_variant] as Player
		if player_node == null or not is_instance_valid(player_node) or not player_node.is_dead:
			continue
		var revive_position: Variant = _resolve_multiplayer_revive_position(
			peer_id,
			revive_positions
		)
		if revive_position is Vector2:
			_revive_player_peer(peer_id, revive_position as Vector2)


@rpc("authority", "call_remote", "reliable", 5)
func net_player_revive_countdown(peer_id: int, seconds_left: int) -> void:
	if game == null or peer_id <= 0:
		return
	if _mode_adapter == null or not _mode_adapter.allows_player_respawn(peer_id):
		if _mode_adapter != null:
			_mode_adapter.clear_player_respawn_countdown(peer_id)
		return
	var player_node := game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if _has_tower_mode():
		_mode_adapter.update_player_respawn_countdown(peer_id, seconds_left)
	else:
		player_node.set_multiplayer_revive_countdown(seconds_left)


@rpc("authority", "call_remote", "reliable", 5)
func net_player_revived(
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
	):
		return
	var player_node: Player = null
	if game != null:
		player_node = game.get_player_for_peer(peer_id)
	if (
		game == null
		or _mode_adapter == null
		or not _mode_adapter.allows_player_respawn(peer_id)
		or player_node == null
		or not is_instance_valid(player_node)
	):
		return
	if health_revision <= int(_player_health_revisions.get(peer_id, 0)):
		return
	_player_health_revisions[peer_id] = health_revision
	# Revive is a reliable lifecycle transition and must run even when a newer
	# alive snapshot was observed first: tower-defense death presentation
	# intentionally refuses to revive from realtime snapshots.
	_mark_player_health_revision_applied(peer_id, health_revision)
	_dead_player_revive_times.erase(peer_id)
	_dead_player_revive_last_seconds.erase(peer_id)
	_active_tiyi_activations_by_peer.erase(peer_id)
	_tiyi_target_ids_by_peer.erase(peer_id)
	player_node.revive_multiplayer(revive_position, current_health, invincible_seconds)
	if _mode_adapter != null:
		_mode_adapter.clear_player_respawn_countdown(peer_id)
	if is_client_view_runtime() and peer_id != _get_client_view_local_peer_id():
		player_coordinator.reset_visual_interpolator_to_state(
			peer_id,
			revive_position,
			Vector2.ZERO,
			player_node.get_multiplayer_facing_id(),
			player_node.get_multiplayer_anim_state(),
			_get_net_time()
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


func _on_host_base_health_changed(
	current_health: int,
	maximum_health: int,
	revision: int
) -> void:
	if not _has_tower_mode() or not is_inside_tree() or not net_manager.is_host():
		return
	if (
		not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(maximum_health)
		or not _NetConstants.is_valid_network_combat_value(revision)
	):
		push_error("MpGame: 基地生命快照超出网络 signed int32 契约，已拒绝发送。")
		return
	_rpc_to_connected_clients(
		&"net_base_health_changed",
		[current_health, maximum_health, revision]
	)


func _on_host_xiaocong_fate_state_changed(state: Dictionary) -> void:
	if (
		not is_inside_tree()
		or not net_manager.is_host()
		or game == null
		or not _has_tower_mode()
	):
		return
	_rpc_to_connected_clients(
		&"net_xiaocong_fate_state_changed",
		[state.duplicate(true)]
	)


func _on_host_test_arena_manual_night_changed(enabled: bool) -> void:
	if (
		not is_inside_tree()
		or not net_manager.is_host()
		or not _has_tower_mode()
		or not tower_mode_adapter.supports_test_arena_manual_night_sync()
	):
		return
	_rpc_to_connected_clients(
		&"net_test_arena_manual_night_changed",
		[enabled]
	)


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


func _broadcast_base_health_snapshot() -> void:
	if not _has_tower_mode() or not net_manager.is_host():
		return
	var snapshot := tower_mode_adapter.get_base_health_snapshot()
	if snapshot.is_empty():
		return
	_on_host_base_health_changed(
		int(snapshot.get("current_health", 0)),
		int(snapshot.get("maximum_health", 1)),
		int(snapshot.get("revision", 0))
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


func _on_host_plant_placement_rejected(
	request_id: int,
	requester_peer_id: int,
	reason: StringName
) -> void:
	if not _has_tower_mode() or not is_inside_tree() or not net_manager.is_host():
		return
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
	if net_manager.has_method("is_peer_send_ready"):
		if not bool(net_manager.call("is_peer_send_ready", requester_peer_id)):
			return
	net_plant_placement_rejected.rpc_id(
		requester_peer_id,
		request_id,
		String(reason)
	)


func _on_host_plant_health_changed(
	net_id: int,
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
		push_error("MpGame: 植物生命更新超出网络 signed int32 契约，已拒绝入队。")
		return
	var previous := _pending_plant_health_updates.get(net_id, {}) as Dictionary
	if int(previous.get("health_revision", -1)) > health_revision:
		return
	previous["current_health"] = current_health
	previous["maximum_health"] = maximum_health
	previous["health_revision"] = health_revision
	_pending_plant_health_updates[net_id] = previous


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


func _on_host_plant_damage_applied(
	net_id: int,
	applied_damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	world_position: Vector2
) -> void:
	if (
		not _has_tower_mode()
		or not is_inside_tree()
		or not net_manager.is_host()
		or net_id <= 0
		or applied_damage <= 0
		or not impact_direction.is_finite()
		or not world_position.is_finite()
	):
		return
	var update := _pending_plant_health_updates.get(net_id, {}) as Dictionary
	if update.is_empty():
		return
	var safe_damage_type := (
		EnemyConfig.DamageType.MAGIC
		if damage_type == EnemyConfig.DamageType.MAGIC
		else EnemyConfig.DamageType.PHYSICAL
	)
	if safe_damage_type == EnemyConfig.DamageType.MAGIC:
		update["magic_damage"] = int(update.get("magic_damage", 0)) + applied_damage
		update["magic_direction"] = impact_direction
	else:
		update["physical_damage"] = int(update.get("physical_damage", 0)) + applied_damage
		update["physical_direction"] = impact_direction
	var physical_damage := int(update.get("physical_damage", 0))
	var magic_damage := int(update.get("magic_damage", 0))
	var use_magic := magic_damage > physical_damage
	update["damage"] = physical_damage + magic_damage
	update["impact_direction"] = (
		update.get("magic_direction", Vector2.ZERO)
		if use_magic
		else update.get("physical_direction", Vector2.ZERO)
	)
	update["damage_type"] = int(
		EnemyConfig.DamageType.MAGIC
		if use_magic
		else EnemyConfig.DamageType.PHYSICAL
	)
	update["world_position"] = world_position
	_pending_plant_health_updates[net_id] = update


func _on_host_plant_healing_applied(
	net_id: int,
	applied_healing: int,
	world_position: Vector2
) -> void:
	if (
		not _has_tower_mode()
		or not is_inside_tree()
		or not net_manager.is_host()
		or net_id <= 0
		or applied_healing <= 0
		or not world_position.is_finite()
	):
		return
	var update := _pending_plant_health_updates.get(net_id, {}) as Dictionary
	if update.is_empty():
		return
	update["healing"] = int(update.get("healing", 0)) + applied_healing
	update["world_position"] = world_position
	_pending_plant_health_updates[net_id] = update


func _on_host_plant_removed(net_id: int, was_destroyed: bool = false) -> void:
	if (
		not _has_tower_mode()
		or not is_inside_tree()
		or not net_manager.is_host()
		or net_id <= 0
	):
		return
	if _pending_plant_health_updates.has(net_id):
		var removed_net_ids: Array[int] = [net_id]
		_send_pending_plant_health_updates(removed_net_ids)
	_pending_plant_health_updates.erase(net_id)
	tower_economy_coordinator.notify_plant_removed(net_id)
	# Bamboo shells are independent pooled visuals after FIRE. Flush their
	# reliable CH_WORLD_EVENT records before the plant removal on that same
	# ordered channel, so clients instantiate the shell while its proxy exists.
	_flush_bamboo_mortar_visuals()
	_rpc_to_connected_clients(&"net_plant_removed", [net_id, was_destroyed])


func _on_host_terrain_delta(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> void:
	if (
		not is_inside_tree()
		or not net_manager.is_host()
		or revision <= _last_host_terrain_revision_broadcast
		or terrain_types.is_empty()
		or not _is_valid_terrain_payload(
			cell_xy,
			terrain_types,
			TERRAIN_DELTA_MAX_CELLS
		)
	):
		return
	_last_host_terrain_revision_broadcast = revision
	_rpc_to_connected_clients(
		&"net_terrain_delta",
		[revision, cell_xy, terrain_types]
	)


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
		_luoxi_offer_states_by_peer.clear()
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
	_dead_player_revive_times.clear()
	_dead_player_revive_last_seconds.clear()


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
	if (
		not net_manager.is_host()
		or not _has_tower_mode()
		or not tower_mode_adapter.supports_terrain_state()
		or known_revision < -1
	):
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0 or game.get_player_for_peer(sender_id) == null:
		return
	if not _consume_peer_rate_token(
		_terrain_snapshot_request_rate_buckets,
		sender_id,
		TERRAIN_SNAPSHOT_REQUEST_RATE_PER_SECOND,
		TERRAIN_SNAPSHOT_REQUEST_RATE_BURST
	):
		return
	_send_terrain_snapshot_to_peer(sender_id)


@rpc("authority", "call_remote", "reliable", 5)
func net_terrain_snapshot_chunk(
	snapshot_id: int,
	revision: int,
	chunk_index: int,
	chunk_count: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> void:
	if (
		net_manager.is_host()
		or not _has_tower_mode()
		or not tower_mode_adapter.supports_terrain_state()
	):
		return
	if snapshot_id <= _last_completed_terrain_snapshot_id:
		return
	if (
		snapshot_id <= 0
		or revision < 0
		or chunk_count <= 0
		or chunk_count > TERRAIN_SNAPSHOT_MAX_CHUNKS
		or chunk_index < 0
		or chunk_index >= chunk_count
		or not _is_valid_terrain_payload(
			cell_xy,
			terrain_types,
			TERRAIN_SNAPSHOT_CHUNK_MAX_CELLS
		)
		or (chunk_index < chunk_count - 1 and terrain_types.size() != TERRAIN_SNAPSHOT_CHUNK_MAX_CELLS)
		or (terrain_types.is_empty() and (chunk_count != 1 or chunk_index != 0))
	):
		_restart_terrain_snapshot_repair()
		return
	_arm_terrain_snapshot_repair_watchdog()

	var batch := _pending_terrain_snapshot_batches.get(snapshot_id, {}) as Dictionary
	if batch.is_empty():
		batch = {
			"revision": revision,
			"chunk_count": chunk_count,
			"chunks": {},
		}
		_pending_terrain_snapshot_batches[snapshot_id] = batch
	elif (
		int(batch.get("revision", -1)) != revision
		or int(batch.get("chunk_count", 0)) != chunk_count
	):
		_restart_terrain_snapshot_repair()
		return

	var chunks := batch.get("chunks", {}) as Dictionary
	if chunks.has(chunk_index):
		var previous := chunks[chunk_index] as Dictionary
		if (
			(previous.get("cell_xy", PackedInt32Array()) as PackedInt32Array) == cell_xy
			and (
				previous.get("terrain_types", PackedInt32Array()) as PackedInt32Array
			) == terrain_types
		):
			return
		_restart_terrain_snapshot_repair()
		return
	chunks[chunk_index] = {
		"cell_xy": cell_xy.duplicate(),
		"terrain_types": terrain_types.duplicate(),
	}
	if chunks.size() < chunk_count:
		return

	var complete_cell_xy := PackedInt32Array()
	var complete_terrain_types := PackedInt32Array()
	for ordered_chunk_index in range(chunk_count):
		if not chunks.has(ordered_chunk_index):
			_restart_terrain_snapshot_repair()
			return
		var chunk := chunks[ordered_chunk_index] as Dictionary
		var ordered_cell_xy: PackedInt32Array = chunk.get("cell_xy", PackedInt32Array())
		var ordered_terrain_types: PackedInt32Array = chunk.get(
			"terrain_types",
			PackedInt32Array()
		)
		complete_cell_xy.append_array(ordered_cell_xy)
		complete_terrain_types.append_array(ordered_terrain_types)
	if not _is_valid_terrain_payload(complete_cell_xy, complete_terrain_types):
		_restart_terrain_snapshot_repair()
		return
	if _client_has_terrain_snapshot and revision < _client_terrain_revision:
		_pending_terrain_snapshot_batches.erase(snapshot_id)
		_client_waiting_for_terrain_snapshot = false
		_terrain_snapshot_repair_watchdog_time_left = 0.0
		return
	if not tower_mode_adapter.apply_remote_terrain_snapshot(
		revision,
		complete_cell_xy,
		complete_terrain_types
	):
		_restart_terrain_snapshot_repair()
		return
	_client_terrain_revision = revision
	_client_has_terrain_snapshot = true
	_client_waiting_for_terrain_snapshot = false
	_terrain_snapshot_repair_watchdog_time_left = 0.0
	_last_completed_terrain_snapshot_id = snapshot_id
	for pending_id_variant in _pending_terrain_snapshot_batches.keys():
		if int(pending_id_variant) <= snapshot_id:
			_pending_terrain_snapshot_batches.erase(pending_id_variant)


@rpc("authority", "call_remote", "reliable", 5)
func net_terrain_delta(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> void:
	if (
		net_manager.is_host()
		or not _has_tower_mode()
		or not tower_mode_adapter.supports_terrain_state()
	):
		return
	if (
		revision <= 0
		or terrain_types.is_empty()
		or not _is_valid_terrain_payload(
			cell_xy,
			terrain_types,
			TERRAIN_DELTA_MAX_CELLS
		)
	):
		_restart_terrain_snapshot_repair()
		return
	if _client_has_terrain_snapshot and revision <= _client_terrain_revision:
		return
	if not _client_has_terrain_snapshot or _client_waiting_for_terrain_snapshot:
		_request_terrain_snapshot_repair()
		return
	if revision != _client_terrain_revision + 1:
		_request_terrain_snapshot_repair()
		return
	if not tower_mode_adapter.apply_remote_terrain_delta(
		revision,
		cell_xy,
		terrain_types
	):
		_request_terrain_snapshot_repair()
		return
	_client_terrain_revision = revision


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
	for net_id in manifest.positive_plant_ids:
		_clear_remote_plant_removed_marker(net_id)

	enemy_coordinator.remove_enemies_missing_from_manifest(manifest.enemy_id_set)
	for net_id_variant in game.multiplayer_pickups.keys():
		var net_id := int(net_id_variant)
		if not manifest.pickup_id_set.has(net_id):
			net_pickup_removed(net_id)
	if _has_tower_mode():
		for plant_snapshot in _get_tower_plant_snapshots():
			var plant_net_id := int(plant_snapshot.get("net_id", 0))
			if plant_net_id > 0 and not manifest.plant_id_set.has(plant_net_id):
				_erase_pending_warehouse_snapshot(plant_net_id)
				_erase_pending_remote_production_state(plant_net_id)
				_mark_remote_plant_removed(plant_net_id)
				tower_mode_adapter.apply_remote_plant_removed(
					plant_net_id,
					false,
					true
				)
			elif plant_net_id > 0:
				_apply_pending_remote_plant_health(plant_net_id)
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
	if not _has_tower_mode() or not net_manager.is_host() or game == null:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	_handle_authoritative_plant_placement_request(
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
	if not _has_tower_mode() or not net_manager.is_host() or game == null:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	_handle_authoritative_inventory_plant_placement_request(
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
	if (
		not _has_tower_mode()
		or net_manager.is_host()
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(maximum_health)
		or not _NetConstants.is_valid_network_combat_value(revision)
	):
		return
	tower_mode_adapter.apply_remote_base_health(
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
	if (
		not _has_tower_mode()
		or net_manager.is_host()
		or multiplayer.get_remote_sender_id() != _get_host_peer_id()
	):
		return
	tower_mode_adapter.apply_remote_xiaocong_fate_state(state)


@rpc("authority", "call_remote", "reliable", 5)
func net_test_arena_manual_night_changed(enabled: bool) -> void:
	if (
		not _has_tower_mode()
		or net_manager.is_host()
		or multiplayer.get_remote_sender_id() != _get_host_peer_id()
		or not tower_mode_adapter.supports_test_arena_manual_night_sync()
	):
		return
	tower_mode_adapter.apply_remote_test_arena_manual_night(enabled)


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
	if (
		not _has_tower_mode()
		or game == null
		or net_manager.is_host()
		or net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(maximum_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
	):
		return
	_clear_remote_plant_removed_marker(net_id)
	tower_mode_adapter.apply_remote_plant_spawn(
		request_id,
		owner_peer_id,
		net_id,
		StringName(plant_id),
		anchor,
		current_health,
		maximum_health,
		health_revision
	)
	var plant := _get_tower_plant(net_id)
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
	_apply_pending_remote_plant_health(net_id)


@rpc("authority", "call_remote", "reliable", 5)
func net_plant_placement_rejected(request_id: int, reason: String) -> void:
	if not _has_tower_mode() or game == null or net_manager.is_host():
		return
	tower_mode_adapter.apply_remote_plant_placement_rejected(
		request_id,
		StringName(reason)
	)


@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_plant_health_changed(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	if (
		not _has_tower_mode()
		or game == null
		or net_manager.is_host()
		or net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(maximum_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
	):
		return
	_apply_or_defer_remote_plant_health(
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
	if not _has_tower_mode() or game == null or net_manager.is_host() or net_id <= 0:
		return
	var plant := _get_tower_plant(net_id)
	if plant == null or not is_instance_valid(plant):
		return
	plant.apply_remote_damage_status_mask(status_mask, status_revision)


@rpc("authority", "call_remote", "reliable", 5)
func net_plant_removed(net_id: int, was_destroyed: bool = false) -> void:
	if not _has_tower_mode() or game == null or net_manager.is_host():
		return
	_erase_pending_warehouse_snapshot(net_id)
	_erase_pending_remote_production_state(net_id)
	_mark_remote_plant_removed(net_id)
	tower_mode_adapter.apply_remote_plant_removed(net_id, was_destroyed)
	_try_apply_pending_warehouse_snapshots_atomically()


@rpc("authority", "call_remote", "unreliable_ordered", 4)
func net_plant_projectile_visual(
	spawn_position: Vector2,
	direction: Vector2,
	speed: float,
	explosion_radius: float,
	lifetime: float
) -> void:
	if (
		not _has_tower_mode()
		or game == null
		or net_manager.is_host()
		or not _is_finite_vector2(spawn_position)
		or not _is_finite_vector2(direction)
		or direction.length_squared() <= 0.001
	):
		return
	if _agave_cannonball_scene == null:
		_agave_cannonball_scene = load(AGAVE_CANNONBALL_SCENE_PATH) as PackedScene
	if _agave_cannonball_scene == null:
		return
	var projectile := _acquire_or_instantiate_projectile(
		_agave_cannonball_scene
	) as Node2D
	if projectile == null:
		return
	projectile.top_level = true
	if projectile.get_parent() == null:
		add_child(projectile)
	projectile.global_position = spawn_position
	projectile.call(
		"setup",
		direction.normalized(),
		0,
		maxf(speed, 0.0),
		maxf(explosion_radius, 1.0),
		maxf(lifetime, 0.01),
		false,
		0
	)
	projectile.reset_physics_interpolation()


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
	if (
		not _has_tower_mode()
		or game == null
		or net_manager.is_host()
		or not _is_valid_bamboo_mortar_visual_payload(
			plant_net_ids,
			action_ids,
			stages,
			spawn_positions,
			landing_positions,
			committed_windup_durations,
			host_action_times
		)
	):
		return
	for record_index in range(plant_net_ids.size()):
		var mortar := _get_tower_plant(
			plant_net_ids[record_index]
		)
		if (
			mortar == null
			or not is_instance_valid(mortar)
			or mortar.get_script() != BAMBOO_MORTAR_SCRIPT
		):
			continue
		var mapped_action_time := _map_host_timestamp_to_client_time(
			host_action_times[record_index],
			false
		)
		var elapsed := maxf(
			_get_net_time() - mapped_action_time,
			0.0
		)
		if not is_finite(elapsed):
			continue
		mortar.call(
			"play_multiplayer_action",
			int(stages[record_index]),
			action_ids[record_index],
			spawn_positions[record_index],
			landing_positions[record_index],
			elapsed,
			committed_windup_durations[record_index]
		)


@rpc("authority", "call_remote", "reliable", 5)
func net_hydrangea_rain_visual(
	plant_net_id: int,
	action_id: int,
	target_position: Vector2,
	host_action_time: float
) -> void:
	if (
		not _has_tower_mode()
		or game == null
		or net_manager.is_host()
		or plant_net_id <= 0
		or action_id <= 0
		or not _is_finite_vector2(target_position)
		or not is_finite(host_action_time)
	):
		return
	var hydrangea := _get_tower_plant(plant_net_id)
	if (
		hydrangea == null
		or not is_instance_valid(hydrangea)
		or hydrangea.get_script() != HYDRANGEA_RAIN_TOWER_SCRIPT
	):
		return
	var mapped_action_time := _map_host_timestamp_to_client_time(
		host_action_time,
		false
	)
	var elapsed := maxf(_get_net_time() - mapped_action_time, 0.0)
	if not is_finite(elapsed):
		return
	hydrangea.call(
		"play_multiplayer_rain_action",
		action_id,
		target_position,
		elapsed
	)


@rpc("authority", "call_remote", "unreliable_ordered", 4)
func net_corn_machine_gun_burst_batch(
	plant_net_ids: PackedInt32Array,
	action_ids: PackedInt32Array,
	directions: PackedVector2Array,
	host_action_times: PackedFloat64Array
) -> void:
	if (
		not _has_tower_mode()
		or game == null
		or net_manager.is_host()
		or not _is_valid_corn_machine_gun_burst_payload(
			plant_net_ids,
			action_ids,
			directions,
			host_action_times
		)
	):
		return
	for record_index in range(plant_net_ids.size()):
		var corn := _get_tower_plant(plant_net_ids[record_index])
		if (
			corn == null
			or not is_instance_valid(corn)
			or corn.get_script() != CORN_MACHINE_GUN_SCRIPT
		):
			continue
		var mapped_action_time := _map_host_timestamp_to_client_time(
			host_action_times[record_index],
			false
		)
		var elapsed := maxf(_get_net_time() - mapped_action_time, 0.0)
		if not is_finite(elapsed):
			continue
		corn.call(
			"play_multiplayer_burst",
			directions[record_index].normalized(),
			action_ids[record_index],
			elapsed
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
	if not net_manager.is_host() or not _has_tower_mode():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not _admit_remote_xiaocong_request(sender_id):
		return
	tower_mode_adapter.request_xiaocong_interaction(sender_id)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_xiaocong_fate_vote_requested(
	option_id: String,
	permanent_buff_id: String
) -> void:
	var typed_option_id := StringName(option_id)
	var typed_buff_id := StringName(permanent_buff_id)
	if (
		not net_manager.is_host()
		or not _has_tower_mode()
		or option_id.length() > TowerDefenseFateRegistry.MAX_WIRE_ID_LENGTH
		or permanent_buff_id.length() > TowerDefenseFateRegistry.MAX_WIRE_ID_LENGTH
		or not _is_valid_xiaocong_vote_payload(typed_option_id, typed_buff_id)
	):
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not _admit_remote_xiaocong_request(sender_id):
		return
	tower_mode_adapter.request_xiaocong_fate_vote(
		sender_id,
		typed_option_id,
		typed_buff_id
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_xiaocong_collectible_choice_requested(choice_index: int) -> void:
	if (
		not net_manager.is_host()
		or not _has_tower_mode()
		or choice_index < 0
		or choice_index > 3
	):
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not _admit_remote_xiaocong_request(sender_id):
		return
	tower_mode_adapter.request_xiaocong_collectible_choice(
		sender_id,
		choice_index
	)


func _admit_remote_xiaocong_request(sender_id: int) -> bool:
	if (
		sender_id <= 0
		or game == null
		or game.get_player_for_peer(sender_id) == null
	):
		return false
	return (
		transactions_coordinator.consume_remote_transaction_admission(sender_id)
		and _consume_peer_rate_token(
			_xiaocong_transaction_rate_buckets,
			sender_id,
			XIAOCONG_TRANSACTION_RATE_PER_SECOND,
			XIAOCONG_TRANSACTION_RATE_BURST
		)
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_collectible_offer_requested() -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	if (
		not transactions_coordinator.consume_remote_transaction_admission(sender_id)
		or not _consume_peer_rate_token(
			_luoxi_transaction_rate_buckets,
			sender_id,
			LUOXI_TRANSACTION_RATE_PER_SECOND,
			LUOXI_TRANSACTION_RATE_BURST
		)
	):
		return
	_send_or_create_luoxi_offer_for_peer(sender_id)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_collectible_choice_requested(
	choice_index: int,
	offer_revision: int = 0
) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	if (
		not transactions_coordinator.consume_remote_transaction_admission(sender_id)
		or not _consume_peer_rate_token(
			_luoxi_transaction_rate_buckets,
			sender_id,
			LUOXI_TRANSACTION_RATE_PER_SECOND,
			LUOXI_TRANSACTION_RATE_BURST
		)
	):
		return
	_apply_luoxi_collectible_choice_for_peer(
		sender_id,
		choice_index,
		"",
		offer_revision,
		true
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_collectible_refresh_requested(offer_revision: int = 0) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	if (
		not transactions_coordinator.consume_remote_transaction_admission(sender_id)
		or not _consume_peer_rate_token(
			_luoxi_transaction_rate_buckets,
			sender_id,
			LUOXI_TRANSACTION_RATE_PER_SECOND,
			LUOXI_TRANSACTION_RATE_BURST
		)
	):
		return
	_apply_luoxi_collectible_refresh_for_peer(sender_id, offer_revision, true)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_special_game_start_requested() -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	if (
		not transactions_coordinator.consume_remote_transaction_admission(sender_id)
		or not _consume_peer_rate_token(
			_luoxi_transaction_rate_buckets,
			sender_id,
			LUOXI_TRANSACTION_RATE_PER_SECOND,
			LUOXI_TRANSACTION_RATE_BURST
		)
	):
		return
	_apply_luoxi_special_game_start_for_peer(sender_id)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_special_game_card_reveal_requested(
	session_revision: int,
	card_index: int
) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	if (
		not transactions_coordinator.consume_remote_transaction_admission(sender_id)
		or not _consume_peer_rate_token(
			_luoxi_transaction_rate_buckets,
			sender_id,
			LUOXI_TRANSACTION_RATE_PER_SECOND,
			LUOXI_TRANSACTION_RATE_BURST
		)
	):
		return
	_apply_luoxi_special_game_card_reveal_for_peer(
		sender_id,
		session_revision,
		card_index
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_special_game_finish_requested(session_revision: int) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	if (
		not transactions_coordinator.consume_remote_transaction_admission(sender_id)
		or not _consume_peer_rate_token(
			_luoxi_transaction_rate_buckets,
			sender_id,
			LUOXI_TRANSACTION_RATE_PER_SECOND,
			LUOXI_TRANSACTION_RATE_BURST
		)
	):
		return
	_apply_luoxi_special_game_finish_for_peer(
		sender_id,
		session_revision
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_cheat_xirang_requested() -> void:
	if not net_manager.is_host() or not OS.is_debug_build():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	_apply_cheat_xirang_for_peer(sender_id)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_debug_collectible_requested(config_path: String) -> void:
	if (
		not net_manager.is_host()
		or game == null
		or _mode_adapter == null
		or not _mode_adapter.allows_debug_collectible_grants()
	):
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	_apply_debug_collectible_for_peer(sender_id, config_path)


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
	if game == null or peer_id != _get_local_peer_id():
		return
	_luoxi_offer_states_by_peer[peer_id] = {
		"offer_revision": offer_revision,
		"config_paths": Array(config_paths),
		"refresh_count": refresh_count,
	}
	var merchant := _get_luoxi_merchant()
	if merchant == null:
		return
	merchant.apply_authoritative_offer_state(
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
	if game == null or _mode_adapter == null:
		return
	if not inventory_snapshot.is_empty():
		run_state.apply_inventory_snapshot_for_peer(peer_id, inventory_snapshot)
	if result_code == MerchantPurchaseResult.CollectibleClaim.SUCCESS and not config_path.is_empty():
		var already_applied_on_host: bool = net_manager.is_host() and peer_id == _get_local_peer_id()
		if not already_applied_on_host:
			_mode_adapter.runtime_record_luoxi_collectible_claim(peer_id)
			if inventory_snapshot.is_empty():
				var item := load(config_path) as PickupConfig
				if item != null:
					run_state.try_add_item_for_peer(peer_id, item)
	elif result_code == MerchantPurchaseResult.CollectibleClaim.ALREADY_CLAIMED:
		_mode_adapter.runtime_mark_luoxi_collectible_claimed(peer_id)
	if peer_id == _get_local_peer_id():
		if result_code == MerchantPurchaseResult.CollectibleClaim.STALE_OFFER:
			return
		_mode_adapter.show_local_luoxi_collectible_result(result_code)


@rpc("authority", "call_remote", "reliable", 6)
func net_luoxi_collectible_refresh_confirmed(
	peer_id: int,
	result_code: int,
	refresh_count: int,
	current_xirang: int
) -> void:
	if game == null or _mode_adapter == null:
		return
	var player_node: Player = game.get_player_for_peer(peer_id)
	if player_node != null and is_instance_valid(player_node):
		var already_applied_on_host: bool = net_manager.is_host() and peer_id == _get_local_peer_id()
		if not already_applied_on_host:
			var xirang_delta := current_xirang - player_node.current_xirang
			player_node.current_xirang = maxi(current_xirang, 0)
			player_node.xirang_changed.emit(player_node.current_xirang, xirang_delta)
	if peer_id == _get_local_peer_id():
		_mode_adapter.show_local_luoxi_refresh_result(
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
	if game == null or _mode_adapter == null or peer_id <= 0:
		return
	if not inventory_snapshot.is_empty():
		run_state.apply_inventory_snapshot_for_peer(peer_id, inventory_snapshot)
	if peer_id == _get_local_peer_id():
		_mode_adapter.show_local_luoxi_special_game_started(result)


@rpc("authority", "call_remote", "reliable", 6)
func net_luoxi_special_game_card_revealed(
	peer_id: int,
	result: Dictionary
) -> void:
	if game == null or _mode_adapter == null or peer_id <= 0:
		return
	if peer_id == _get_local_peer_id():
		_mode_adapter.show_local_luoxi_special_game_card_revealed(result)


@rpc("authority", "call_remote", "reliable", 6)
func net_luoxi_special_game_finished(
	peer_id: int,
	result: Dictionary,
	inventory_snapshot: Dictionary = {}
) -> void:
	if game == null or _mode_adapter == null or peer_id <= 0:
		return
	if not inventory_snapshot.is_empty():
		run_state.apply_inventory_snapshot_for_peer(peer_id, inventory_snapshot)
	var player_node := game.get_player_for_peer(peer_id)
	if player_node != null and is_instance_valid(player_node):
		var confirmed_xirang := int(
			result.get("current_xirang", player_node.current_xirang)
		)
		var already_applied_on_host: bool = (
			net_manager.is_host() and peer_id == _get_local_peer_id()
		)
		if not already_applied_on_host and confirmed_xirang != player_node.current_xirang:
			var xirang_delta := confirmed_xirang - player_node.current_xirang
			player_node.current_xirang = maxi(confirmed_xirang, 0)
			player_node.xirang_changed.emit(
				player_node.current_xirang,
				xirang_delta
			)
	if peer_id == _get_local_peer_id():
		_mode_adapter.show_local_luoxi_special_game_finished(result)


@rpc("authority", "call_remote", "unreliable", 7)
func net_collectible_visual_effect(
	effect_type: String,
	spawn_position: Vector2,
	radius: float,
	color: Color,
	duration: float,
	effect_event_id: int = 0
) -> void:
	if not _accept_collectible_effect_event(effect_event_id):
		return
	_spawn_collectible_visual_effect(effect_type, spawn_position, radius, color, duration)


@rpc("authority", "call_remote", "unreliable", 7)
func net_collectible_follow_visual_effect(
	effect_type: String,
	owner_peer_id: int,
	radius: float,
	duration: float,
	effect_event_id: int = 0
) -> void:
	if not _accept_collectible_effect_event(effect_event_id):
		return
	_spawn_collectible_follow_visual_effect(effect_type, owner_peer_id, radius, duration)


func _accept_collectible_effect_event(effect_event_id: int) -> bool:
	if effect_event_id <= 0:
		return true
	var now := _get_net_time()
	if _is_recent_event_cached(
		_processed_collectible_effect_event_ids,
		effect_event_id,
		now
	):
		return false
	_remember_recent_event(
		_processed_collectible_effect_event_ids,
		effect_event_id,
		COLLECTIBLE_EFFECT_DEDUP_RETENTION_SECONDS,
		now
	)
	return true


@rpc("authority", "call_remote", "reliable", 6)
func net_cheat_xirang_confirmed(peer_id: int, current_xirang: int, added_amount: int) -> void:
	if game == null:
		return
	var player_node := game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	player_node.current_xirang = maxi(current_xirang, 0)
	player_node.xirang_changed.emit(player_node.current_xirang, maxi(added_amount, 0))


@rpc("authority", "call_remote", "reliable", 6)
func net_debug_collectible_granted(
	peer_id: int,
	config_path: String,
	success: bool,
	inventory_snapshot: Dictionary = {}
) -> void:
	if game == null:
		return
	if peer_id <= 0:
		return
	var player_node: Player = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if not inventory_snapshot.is_empty():
		run_state.apply_inventory_snapshot_for_peer(peer_id, inventory_snapshot)
	elif success and not config_path.is_empty():
		# Compatibility for confirmations produced before authoritative snapshots.
		var already_applied_on_host: bool = net_manager != null and net_manager.is_host() and peer_id == _get_local_peer_id()
		if not already_applied_on_host:
			var item := LuoxiMerchant.get_collectible_for_path(config_path)
			if item != null:
				run_state.try_add_item_for_peer(peer_id, item)
	if peer_id == _get_local_peer_id():
		if _mode_adapter != null:
			_mode_adapter.show_debug_collectible_grant_result(
				config_path,
				success
			)


func _get_luoxi_merchant() -> LuoxiMerchant:
	if _mode_adapter == null:
		return null
	return _mode_adapter.get_luoxi_merchant()


func _send_or_create_luoxi_offer_for_peer(peer_id: int) -> void:
	if game == null or peer_id <= 0 or not net_manager.is_host():
		return
	var state := _ensure_luoxi_offer_for_peer(peer_id)
	if state.is_empty():
		return
	_send_luoxi_offer_state_to_peer(peer_id, state)


func _ensure_luoxi_offer_for_peer(peer_id: int) -> Dictionary:
	var existing := _luoxi_offer_states_by_peer.get(peer_id, {}) as Dictionary
	if not existing.is_empty():
		return existing
	return _create_luoxi_offer_for_peer(peer_id, [])


func _create_luoxi_offer_for_peer(
	peer_id: int,
	excluded_paths: Array[String]
) -> Dictionary:
	if (
		_mode_adapter == null
		or peer_id <= 0
		or _mode_adapter.runtime_has_luoxi_collectible_claimed(peer_id)
	):
		return {}
	var player_node: Player = game.get_player_for_peer(peer_id)
	var merchant := _get_luoxi_merchant()
	if (
		player_node == null
		or not is_instance_valid(player_node)
		or merchant == null
		or not is_instance_valid(merchant)
	):
		return {}
	var config_paths := merchant.build_authoritative_offer_paths(
		player_node,
		excluded_paths,
		_luoxi_offer_random_generator
	)
	if config_paths.size() != LuoxiMerchant.get_choice_count():
		return {}
	return _commit_luoxi_offer_state(peer_id, config_paths)


func _commit_luoxi_offer_state(
	peer_id: int,
	config_paths: Array[String]
) -> Dictionary:
	var next_revision := int(_luoxi_offer_revision_counters.get(peer_id, 0)) + 1
	_luoxi_offer_revision_counters[peer_id] = next_revision
	var state := {
		"offer_revision": next_revision,
		"config_paths": config_paths.duplicate(),
		"refresh_count": (
			_mode_adapter.runtime_get_luoxi_collectible_refresh_count(peer_id)
		),
	}
	_luoxi_offer_states_by_peer[peer_id] = state
	return state


func _send_luoxi_offer_state_to_peer(
	peer_id: int,
	state: Dictionary,
	refresh_result_code: int = -1
) -> void:
	if peer_id <= 0 or state.is_empty():
		return
	var player_node: Player = game.get_player_for_peer(peer_id) if game != null else null
	if player_node == null or not is_instance_valid(player_node):
		return
	var packed_paths := PackedStringArray(state.get("config_paths", []) as Array)
	var offer_revision := int(state.get("offer_revision", 0))
	var refresh_count := int(
		state.get(
			"refresh_count",
			_mode_adapter.runtime_get_luoxi_collectible_refresh_count(peer_id)
		)
	)
	if peer_id == _get_local_peer_id():
		net_luoxi_collectible_offer_state(
			peer_id,
			offer_revision,
			packed_paths,
			refresh_count,
			player_node.current_xirang,
			refresh_result_code
		)
		return
	if (
		net_manager.has_method("is_peer_send_ready")
		and not bool(net_manager.call("is_peer_send_ready", peer_id))
	):
		return
	net_luoxi_collectible_offer_state.rpc_id(
		peer_id,
		peer_id,
		offer_revision,
		packed_paths,
		refresh_count,
		player_node.current_xirang,
		refresh_result_code
	)


func _apply_luoxi_special_game_start_for_peer(peer_id: int) -> void:
	if game == null or peer_id <= 0 or not net_manager.is_host():
		return
	var result := (
		_mode_adapter.runtime_try_start_luoxi_special_game_for_peer(peer_id)
	)
	var inventory_snapshot := run_state.export_inventory_snapshot_for_peer(peer_id)
	_rpc_to_connected_clients(
		&"net_luoxi_special_game_started",
		[peer_id, result, inventory_snapshot]
	)
	if peer_id == _get_local_peer_id():
		net_luoxi_special_game_started(
			peer_id,
			result,
			inventory_snapshot
		)


func _apply_luoxi_special_game_card_reveal_for_peer(
	peer_id: int,
	session_revision: int,
	card_index: int
) -> void:
	if game == null or peer_id <= 0 or not net_manager.is_host():
		return
	var result := _mode_adapter.runtime_try_reveal_luoxi_special_game_card_for_peer(
		peer_id,
		session_revision,
		card_index
	)
	_rpc_to_connected_clients(
		&"net_luoxi_special_game_card_revealed",
		[peer_id, result]
	)
	if peer_id == _get_local_peer_id():
		net_luoxi_special_game_card_revealed(peer_id, result)


func _apply_luoxi_special_game_finish_for_peer(
	peer_id: int,
	session_revision: int
) -> void:
	if game == null or peer_id <= 0 or not net_manager.is_host():
		return
	var result := _mode_adapter.runtime_try_finish_luoxi_special_game_for_peer(
		peer_id,
		session_revision
	)
	var inventory_snapshot := run_state.export_inventory_snapshot_for_peer(peer_id)
	_rpc_to_connected_clients(
		&"net_luoxi_special_game_finished",
		[peer_id, result, inventory_snapshot]
	)
	if peer_id == _get_local_peer_id():
		net_luoxi_special_game_finished(
			peer_id,
			result,
			inventory_snapshot
		)


func _apply_luoxi_collectible_choice_for_peer(
	peer_id: int,
	choice_index: int,
	_legacy_config_path: String = "",
	offer_revision: int = 0,
	require_offer_revision: bool = false
) -> void:
	if game == null or peer_id <= 0 or not net_manager.is_host():
		return
	var state := _ensure_luoxi_offer_for_peer(peer_id)
	if state.is_empty():
		_send_luoxi_collectible_confirmation(
			peer_id,
			choice_index,
			"",
			MerchantPurchaseResult.CollectibleClaim.INVALID_PLAYER,
			0
		)
		return
	var authoritative_revision := int(state.get("offer_revision", 0))
	if (
		(require_offer_revision and offer_revision <= 0)
		or (offer_revision > 0 and offer_revision != authoritative_revision)
	):
		_send_luoxi_offer_state_to_peer(peer_id, state)
		_send_luoxi_collectible_confirmation(
			peer_id,
			choice_index,
			"",
			MerchantPurchaseResult.CollectibleClaim.STALE_OFFER,
			authoritative_revision
		)
		return

	var config_paths := state.get("config_paths", []) as Array
	if choice_index < 0 or choice_index >= config_paths.size():
		_send_luoxi_collectible_confirmation(
			peer_id,
			choice_index,
			"",
			MerchantPurchaseResult.CollectibleClaim.INVALID_PLAYER,
			authoritative_revision
		)
		return
	var resolved_config_path := str(config_paths[choice_index])
	var result_code := _mode_adapter.runtime_try_claim_luoxi_collectible_for_peer(
		peer_id,
		resolved_config_path
	)
	if result_code != MerchantPurchaseResult.CollectibleClaim.SUCCESS:
		resolved_config_path = ""
	_send_luoxi_collectible_confirmation(
		peer_id,
		choice_index,
		resolved_config_path,
		result_code,
		authoritative_revision
	)


func _send_luoxi_collectible_confirmation(
	peer_id: int,
	choice_index: int,
	config_path: String,
	result_code: int,
	offer_revision: int
) -> void:
	var inventory_snapshot := run_state.export_inventory_snapshot_for_peer(peer_id)
	_rpc_to_connected_clients(
		&"net_luoxi_collectible_confirmed",
		[
			peer_id,
			choice_index,
			config_path,
			result_code,
			offer_revision,
			inventory_snapshot,
		]
	)
	if peer_id == _get_local_peer_id():
		net_luoxi_collectible_confirmed(
			peer_id,
			choice_index,
			config_path,
			result_code,
			offer_revision,
			inventory_snapshot
		)


func _apply_luoxi_collectible_refresh_for_peer(
	peer_id: int,
	offer_revision: int = 0,
	require_offer_revision: bool = false
) -> void:
	if game == null or peer_id <= 0 or not net_manager.is_host():
		return
	var player_node: Player = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	var state := _ensure_luoxi_offer_for_peer(peer_id)
	if state.is_empty():
		return
	var authoritative_revision := int(state.get("offer_revision", 0))
	if (
		(require_offer_revision and offer_revision <= 0)
		or (offer_revision > 0 and offer_revision != authoritative_revision)
	):
		_send_luoxi_offer_state_to_peer(
			peer_id,
			state,
			MerchantPurchaseResult.OfferRefresh.STALE_OFFER
		)
		return

	var previous_paths: Array[String] = []
	for config_path_variant in state.get("config_paths", []) as Array:
		previous_paths.append(str(config_path_variant))
	var merchant := _get_luoxi_merchant()
	if merchant == null:
		return
	var replacement_paths := merchant.build_authoritative_offer_paths(
		player_node,
		previous_paths,
		_luoxi_offer_random_generator
	)
	if replacement_paths.size() != LuoxiMerchant.get_choice_count():
		_send_luoxi_offer_state_to_peer(
			peer_id,
			state,
			MerchantPurchaseResult.OfferRefresh.INVALID_PLAYER
		)
		return
	var result_code := (
		_mode_adapter.runtime_try_refresh_luoxi_collectibles_for_peer(peer_id)
	)
	if result_code == MerchantPurchaseResult.OfferRefresh.SUCCESS:
		state = _commit_luoxi_offer_state(peer_id, replacement_paths)
	else:
		state["refresh_count"] = (
			_mode_adapter.runtime_get_luoxi_collectible_refresh_count(peer_id)
		)
		_luoxi_offer_states_by_peer[peer_id] = state
	_send_luoxi_offer_state_to_peer(peer_id, state, result_code)


func _spawn_collectible_visual_effect(
	effect_type: String,
	spawn_position: Vector2,
	radius: float,
	color: Color,
	duration: float
) -> void:
	match effect_type:
		"lightning":
			var lightning := COLLECTIBLE_LIGHTNING_EFFECT_SCENE.instantiate() as CollectibleLightningEffect
			if lightning == null:
				return
			lightning.top_level = true
			lightning.setup(duration)
			add_child(lightning)
			lightning.global_position = spawn_position
		"area":
			var area := COLLECTIBLE_AREA_EFFECT_SCENE.instantiate() as CollectibleAreaEffect
			if area == null:
				return
			area.top_level = true
			area.setup(radius, color, duration)
			add_child(area)
			area.global_position = spawn_position
		"frost_area":
			var frost_area := COLLECTIBLE_FROST_AREA_EFFECT_SCENE.instantiate()
			if frost_area == null:
				return
			frost_area.top_level = true
			frost_area.call("setup", radius, duration)
			add_child(frost_area)
			frost_area.global_position = spawn_position


func _spawn_collectible_follow_visual_effect(
	effect_type: String,
	owner_peer_id: int,
	radius: float,
	duration: float
) -> void:
	if game == null or owner_peer_id <= 0:
		return
	var owner_player := game.get_player_for_peer(owner_peer_id)
	if owner_player == null or not is_instance_valid(owner_player):
		return
	match effect_type:
		"moon_shield":
			var moon_shield := COLLECTIBLE_MOON_SHIELD_VISUAL_SCENE.instantiate() as CollectibleMoonShieldVisual
			if moon_shield == null:
				return
			moon_shield.setup(radius, duration)
			owner_player.add_child(moon_shield)
			moon_shield.position = Vector2.ZERO


func _apply_cheat_xirang_for_peer(peer_id: int) -> void:
	if game == null or not OS.is_debug_build():
		return
	var player_node: Player = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if not player_node.grant_cheat_xirang(CHEAT_XIRANG_AMOUNT):
		return
	_rpc_to_connected_clients(
		&"net_cheat_xirang_confirmed",
		[peer_id, player_node.current_xirang, CHEAT_XIRANG_AMOUNT]
	)


func _apply_debug_collectible_for_peer(peer_id: int, config_path: String) -> void:
	if (
		game == null
		or peer_id <= 0
		or _mode_adapter == null
		or not _mode_adapter.allows_debug_collectible_grants()
	):
		return
	var item := LuoxiMerchant.get_collectible_for_path(config_path)
	var success := item != null and run_state.try_add_item_for_peer(peer_id, item)
	var inventory_snapshot := run_state.export_inventory_snapshot_for_peer(peer_id)
	_rpc_to_connected_clients(
		&"net_debug_collectible_granted",
		[peer_id, config_path, success, inventory_snapshot]
	)
	if peer_id == _get_local_peer_id():
		net_debug_collectible_granted(
			peer_id,
			config_path,
			success,
			inventory_snapshot
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


func _request_terrain_snapshot_repair() -> void:
	if (
		_client_waiting_for_terrain_snapshot
		or not net_manager.is_client()
		or not _has_tower_mode()
		or not tower_mode_adapter.supports_terrain_state()
	):
		return
	_send_terrain_snapshot_repair_request()


func _send_terrain_snapshot_repair_request() -> void:
	_client_waiting_for_terrain_snapshot = true
	_arm_terrain_snapshot_repair_watchdog()
	_transmit_terrain_snapshot_repair_request()


func _transmit_terrain_snapshot_repair_request() -> void:
	net_terrain_snapshot_requested.rpc_id(
		_get_host_peer_id(),
		_client_terrain_revision
	)


func _arm_terrain_snapshot_repair_watchdog() -> void:
	_terrain_snapshot_repair_watchdog_time_left = (
		TERRAIN_SNAPSHOT_REPAIR_WATCHDOG_SECONDS
	)


func _update_terrain_snapshot_repair_watchdog(delta: float) -> void:
	if not _client_waiting_for_terrain_snapshot:
		_terrain_snapshot_repair_watchdog_time_left = 0.0
		return
	if (
		not net_manager.is_client()
		or not _has_tower_mode()
		or not tower_mode_adapter.supports_terrain_state()
	):
		return
	_terrain_snapshot_repair_watchdog_time_left = maxf(
		_terrain_snapshot_repair_watchdog_time_left - maxf(delta, 0.0),
		0.0
	)
	if _terrain_snapshot_repair_watchdog_time_left > 0.0:
		return
	# Drop an incomplete assembly before retrying. Each valid incoming chunk arms
	# the watchdog again, so a large snapshot that is still making progress never
	# generates duplicate requests; a silent/rate-limited request retries at most
	# once every watchdog interval.
	_pending_terrain_snapshot_batches.clear()
	_send_terrain_snapshot_repair_request()


func _restart_terrain_snapshot_repair() -> void:
	_pending_terrain_snapshot_batches.clear()
	_client_waiting_for_terrain_snapshot = false
	_terrain_snapshot_repair_watchdog_time_left = 0.0
	_request_terrain_snapshot_repair()


func _is_valid_terrain_payload(
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array,
	maximum_cells: int = 0
) -> bool:
	if cell_xy.size() != terrain_types.size() * 2:
		return false
	if maximum_cells > 0 and terrain_types.size() > maximum_cells:
		return false
	var seen_cells: Dictionary = {}
	for cell_index in range(terrain_types.size()):
		var terrain_type := terrain_types[cell_index]
		if (
			terrain_type != TERRAIN_TYPE_EMPTY
			and terrain_type != TERRAIN_TYPE_GRASS
			and terrain_type != TERRAIN_TYPE_DIRT
		):
			return false
		var cell := Vector2i(cell_xy[cell_index * 2], cell_xy[cell_index * 2 + 1])
		if seen_cells.has(cell):
			return false
		seen_cells[cell] = true
	return true


func _get_net_time() -> float:
	return Time.get_ticks_msec() / 1000.0 - _net_time_origin


func _map_host_timestamp_to_client_time(host_timestamp: float, update_offset: bool = true) -> float:
	var receive_time := _get_net_time()
	var sampled_offset := receive_time - host_timestamp
	if not update_offset:
		if _has_host_time_offset:
			return host_timestamp + _host_to_client_time_offset
		return receive_time
	if not _has_host_time_offset:
		_host_to_client_time_offset = sampled_offset
		_has_host_time_offset = true
	else:
		_host_to_client_time_offset = lerpf(
			_host_to_client_time_offset,
			sampled_offset,
			HOST_TIME_OFFSET_SMOOTH_WEIGHT
		)
	return host_timestamp + _host_to_client_time_offset


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
	_disconnected_player_reconnect_states[peer_id] = {
		"state": player_state,
		"spawn_slot_index": spawn_slot_index,
		"wave_death_count": wave_death_count,
		"owned_plant_net_ids": owned_plant_net_ids,
		"revive_at": float(_dead_player_revive_times.get(peer_id, -1.0)),
		"revive_last_seconds": int(
			_dead_player_revive_last_seconds.get(peer_id, -1)
		),
		"luoxi_offer_state": (
			(_luoxi_offer_states_by_peer.get(peer_id, {}) as Dictionary).duplicate(true)
		),
		"luoxi_offer_revision": int(
			_luoxi_offer_revision_counters.get(peer_id, -1)
		),
		"health_revision": int(_player_health_revisions.get(peer_id, 0)),
		"applied_health_revision": int(
			player_coordinator.get_applied_health_revision(peer_id)
		),
	}


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
	_player_health_revisions[new_peer_id] = int(
		reconnect_state.get("health_revision", 0)
	)
	player_coordinator.set_applied_health_revision(
		new_peer_id,
		int(reconnect_state.get("applied_health_revision", 0))
	)
	var revive_at := float(reconnect_state.get("revive_at", -1.0))
	if (
		net_manager.is_host()
		and revive_at >= 0.0
		and _mode_adapter != null
		and _mode_adapter.allows_player_respawn(new_peer_id)
	):
		_dead_player_revive_times[new_peer_id] = revive_at
		_dead_player_revive_last_seconds[new_peer_id] = int(
			reconnect_state.get("revive_last_seconds", -1)
		)
	var luoxi_offer_state := (
		reconnect_state.get("luoxi_offer_state", {}) as Dictionary
	)
	if not luoxi_offer_state.is_empty():
		_luoxi_offer_states_by_peer[new_peer_id] = luoxi_offer_state.duplicate(true)
	var luoxi_offer_revision := int(
		reconnect_state.get("luoxi_offer_revision", -1)
	)
	if luoxi_offer_revision >= 0:
		_luoxi_offer_revision_counters[new_peer_id] = luoxi_offer_revision
	if player_state != null:
		player_coordinator.restore_reconnected_player_snapshot(
			player_node,
			player_state,
			_get_net_time(),
			net_manager.is_host(),
			_get_client_view_local_peer_id(),
			_local_tango_active_request_id > 0
		)
		if net_manager.is_host():
			_accepted_player_state_positions[new_peer_id] = player_state.position
			_accepted_player_state_times[new_peer_id] = _get_net_time()
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
	var preserve_tango_surge_world_state := (
		_active_tango_electric_surges_by_peer.has(peer_id)
	)
	if preserve_tango_surge_world_state:
		var surge_record := _active_tango_electric_surges_by_peer.get(
			peer_id,
			{}
		) as Dictionary
		surge_record["owner_disconnected"] = true
		_active_tango_electric_surges_by_peer[peer_id] = surge_record
	var active_tiyi_activation_id := int(_active_tiyi_activations_by_peer.get(peer_id, 0))
	if active_tiyi_activation_id > 0 and net_manager != null and net_manager.is_host():
		_cancel_authoritative_tiyi_high_noon(peer_id, active_tiyi_activation_id, true)
	if (
		_active_tango_charges_by_peer.has(peer_id)
		and net_manager != null
		and net_manager.is_host()
	):
		_cancel_authoritative_tango_charge(peer_id, true)
	enemy_coordinator.clear_peer(peer_id)
	player_coordinator.clear_peer(peer_id)
	_last_plant_placement_request_ids.erase(peer_id)
	_last_player_state_sequences.erase(peer_id)
	_last_dash_request_sequences.erase(peer_id)
	_last_dash_confirmed_sequences.erase(peer_id)
	_last_dash_accepted_times.erase(peer_id)
	_hoe_action_sequences_by_peer.erase(peer_id)
	_last_hoe_action_request_ids.erase(peer_id)
	_tango_charge_sequences_by_peer.erase(peer_id)
	_last_tango_volley_visual_state_by_peer.erase(peer_id)
	_last_tango_charge_request_ids.erase(peer_id)
	_active_tango_charges_by_peer.erase(peer_id)
	if not preserve_tango_surge_world_state:
		_tango_electric_surge_sequences_by_peer.erase(peer_id)
		_last_tango_electric_surge_request_ids.erase(peer_id)
		_active_tango_electric_surges_by_peer.erase(peer_id)
		_last_tango_electric_surge_seen_by_peer.erase(peer_id)
	_tiyi_activation_sequences_by_peer.erase(peer_id)
	_active_tiyi_activations_by_peer.erase(peer_id)
	_tiyi_target_ids_by_peer.erase(peer_id)
	_last_tiyi_activation_seen_by_peer.erase(peer_id)
	_accepted_player_state_positions.erase(peer_id)
	_accepted_player_state_times.erase(peer_id)
	_player_health_revisions.erase(peer_id)
	_dead_player_revive_times.erase(peer_id)
	_dead_player_revive_last_seconds.erase(peer_id)
	_luoxi_offer_states_by_peer.erase(peer_id)
	_luoxi_offer_revision_counters.erase(peer_id)
	_plant_placement_rate_buckets.erase(peer_id)
	_player_action_ingress_rate_buckets.erase(peer_id)
	_luoxi_transaction_rate_buckets.erase(peer_id)
	_xiaocong_transaction_rate_buckets.erase(peer_id)
	session_coordinator.clear_peer(peer_id)
	transactions_coordinator.clear_peer(peer_id)
	tower_economy_coordinator.clear_peer(peer_id)
	_terrain_snapshot_request_rate_buckets.erase(peer_id)
	projectile_coordinator.clear_peer(peer_id)


func _clear_projectiles_for_peer(peer_id: int) -> void:
	projectile_coordinator.clear_projectiles_for_peer(peer_id)


func _clear_projectile_records_for_peer(peer_id: int) -> void:
	projectile_coordinator.clear_projectile_records_for_peer(peer_id)


func _return_to_lobby() -> void:
	player_coordinator.reset_session_state()
	enemy_coordinator.reset_session_state()
	projectile_coordinator.reset_session_state()
	world_flow_coordinator.reset_session_state()
	_disconnected_player_reconnect_states.clear()
	_processed_collectible_effect_event_ids.clear()
	_pending_plant_health_updates.clear()
	_clear_remote_plant_health_state()
	tower_economy_coordinator.reset_session_state()
	_pending_terrain_snapshot_batches.clear()
	_terrain_snapshot_request_rate_buckets.clear()
	_client_terrain_revision = -1
	_last_host_terrain_revision_broadcast = 0
	_client_has_terrain_snapshot = false
	_client_waiting_for_terrain_snapshot = false
	_terrain_snapshot_repair_watchdog_time_left = 0.0
	_last_completed_terrain_snapshot_id = 0
	_luoxi_offer_states_by_peer.clear()
	_luoxi_offer_revision_counters.clear()
	_luoxi_transaction_rate_buckets.clear()
	_xiaocong_transaction_rate_buckets.clear()
	session_coordinator.reset_session_state()
	transactions_coordinator.reset_session_state()
	_hoe_action_sequences_by_peer.clear()
	_tango_charge_sequences_by_peer.clear()
	_last_tango_volley_visual_state_by_peer.clear()
	_last_tango_charge_request_ids.clear()
	_active_tango_charges_by_peer.clear()
	_tango_electric_surge_sequences_by_peer.clear()
	_last_tango_electric_surge_request_ids.clear()
	_active_tango_electric_surges_by_peer.clear()
	_last_tango_electric_surge_seen_by_peer.clear()
	_local_tango_active_request_id = 0
	_local_tango_release_pending = false
	_local_tango_electric_surge_request_id = 0
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	tree.change_scene_to_file("res://scene/multiplayer/multiplayer_lobby.tscn")
