extends Node2D

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const MultiplayerRuntimeMetricsScript := preload(
	"res://scene/multiplayer/multiplayer_runtime_metrics.gd"
)
const TRANSACTION_RPC_METHODS := {
	&"net_inventory_snapshot": true,
	&"net_inventory_item_used": true,
	&"net_inventory_item_discarded": true,
	&"net_pickup_collected": true,
	&"net_upgrade_confirmed": true,
	&"net_skill1_purchase_confirmed": true,
	&"net_luoxi_collectible_confirmed": true,
	&"net_luoxi_collectible_offer_state": true,
	&"net_luoxi_collectible_refresh_confirmed": true,
	&"net_warehouse_command_result": true,
	&"net_warehouse_storage_snapshot": true,
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
	&"net_plant_health_batch": true,
	&"net_tower_defense_wave_progress_changed": true,
}
const STANDARD_GAME_SCENE_PATH := "res://scene/game.tscn"
const TOWER_DEFENSE_GAME_SCENE_PATH := "res://scene/game_tower_defense.tscn"
const AGAVE_CANNONBALL_SCENE_PATH := "res://scene/plant_defense/agave_cannonball.tscn"
const CORN_MACHINE_GUN_SCRIPT := preload("res://scene/plant_defense/corn_machine_gun.gd")
const PICKUP_SCENE := preload("res://scene/pickup.tscn")
const BULLET_SCENE_PATH := "res://scene/bullet.tscn"
const TIYI_SNIPER_BULLET_SCENE_PATH := "res://scene/player/tiyi/tiyi_sniper_bullet.tscn"
const TIYI_SNIPER_HIT_EFFECT_SCENE_PATH := (
	"res://scene/player/tiyi/tiyi_sniper_hit_effect.tscn"
)
const COLLECTIBLE_ARROW_PROJECTILE_SCENE := preload("res://scene/collectible_arrow_projectile.tscn")
const COLLECTIBLE_ARROW_PROJECTILE_SCRIPT := preload("res://scene/collectible_arrow_projectile.gd")
const SKILL1_BOMB_SCENE_PATH := (
	"res://scene/player/weishidaier/weishidaier_skill1_bomb.tscn"
)
const COLLECTIBLE_AREA_EFFECT_SCENE := preload("res://scene/collectible_area_effect.tscn")
const COLLECTIBLE_FROST_AREA_EFFECT_SCENE := preload("res://scene/collectible_frost_area_effect.tscn")
const COLLECTIBLE_LIGHTNING_EFFECT_SCENE := preload("res://scene/collectible_lightning_effect.tscn")
const COLLECTIBLE_MOON_SHIELD_VISUAL_SCENE := preload("res://scene/collectible_moon_shield_visual.tscn")
const CAPOO_AK47_BULLET_SCENE := preload("res://scene/enemy/capoo_ak47_bullet.tscn")
const CAPOO_RPG_ROCKET_SCENE := preload("res://scene/enemy/capoo_rpg_rocket.tscn")
const CAPOO_MAGE_FIREBALL_SCENE := preload("res://scene/enemy/capoo_mage_fireball.tscn")
const CAPOO_SMG_BULLET_SCENE := preload("res://scene/enemy/capoo_smg_bullet.tscn")
const YUANSHI_FIRE_PROJECTILE_SCENE := preload("res://scene/enemy/yuanshi_insect_fire_projectile.tscn")
const LINGLAN_SAKURA_BULLET_SCENE_PATH := "res://scene/boss/linglan/linglan_skill1_sakura_bullet.tscn"
const LINGLAN_SKILL2_CONFIG_PATH := "res://resources/config/bosses/linglan_skill2.tres"
const LINGLAN_SKILL2_ROCKET_SCENE_PATH := "res://scene/boss/linglan/linglan_skill2_sakura_rocket.tscn"
const COLLECTIBLE_SAKURA_ROCKET_SCENE_PATH := "res://scene/collectible_sakura_rocket.tscn"
const LINGLAN_SKILL3_CONFIG_PATH := "res://resources/config/bosses/linglan_skill3.tres"
const LINGLAN_SKILL3_ORB_SCENE_PATH := "res://scene/boss/linglan/linglan_skill3_light_orb.tscn"
const LINGLAN_SKILL4_CONFIG_PATH := "res://resources/config/bosses/linglan_skill4.tres"
const LINGLAN_SKILL4_ORB_SCENE_PATH := "res://scene/boss/linglan/linglan_skill4_light_orb.tscn"
const LINGLAN_SKILL4_ORB_SCRIPT_PATH := "res://scene/boss/linglan/linglan_skill4_light_orb.gd"
const OakWarehouseProtocolScript := preload("res://scene/plant_defense/oak_warehouse_protocol.gd")

const INPUT_BUTTON_RELOAD := 2
const INPUT_BUTTON_DASH := 4
const DASH_INPUT_REDUNDANCY_PACKETS := 3
const DASH_COOLDOWN_NETWORK_TOLERANCE_SECONDS := 0.35
const HOE_ACTION_PRIMARY := &"primary"
const HOE_ACTION_WHIRLWIND := &"whirlwind"
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
const PROJECTILE_RECORD_RETENTION_SECONDS := 5.0
## Projectile IDs use one positive signed 64-bit value on the wire:
## [31-bit owner peer id][1-bit origin lane][31-bit per-process counter].
## Keeping the owner field disjoint avoids the old decimal namespace spilling
## into the next owner after one million projectiles. The origin lane also keeps
## Host-authored projectiles disjoint from a remote client's predicted shots
## when both processes allocate concurrently for the same owner peer.
const PROJECTILE_ID_SEQUENCE_BITS := 32
const PROJECTILE_ID_SEQUENCE_MASK: int = 0xFFFFFFFF
const PROJECTILE_ID_HOST_ORIGIN_BIT: int = 0x80000000
const PROJECTILE_ID_SEQUENCE_COUNTER_MASK: int = 0x7FFFFFFF
const PROJECTILE_ID_MAX_OWNER_PEER_ID: int = 0x7FFFFFFF
const PROJECTILE_ID_FALLBACK_OWNER_PEER_ID := 999999
const CLIENT_PROJECTILE_SPAWN_POSITION_TOLERANCE := 224.0
const CLIENT_PROJECTILE_DIRECTION_MIN_LENGTH := 0.2
const CLIENT_PROJECTILE_DIRECTION_MAX_LENGTH := 1.5
const CLIENT_PROJECTILE_REQUEST_RATE_PER_SECOND := 256.0
const CLIENT_PROJECTILE_REQUEST_RATE_BURST := 64.0
const PROJECTILE_TIME_COMPENSATION_MAX_SECONDS := 0.25
const LINGLAN_SKILL1_RING_MAX_PROJECTILES_PER_PACKET := 32
const TIYI_SNIPER_PROJECTILE_TYPE: StringName = &"tiyi_sniper_bullet"
const TIYI_HIGH_NOON_MAX_TARGETS := 25
# Application payload budget. Keep room for Godot RPC, ENet, UDP/IP headers before MTU pressure.
const SNAPSHOT_PACKET_WARN_BYTES := 1200
const SNAPSHOT_PACKET_WARN_INTERVAL_SECONDS := 5.0
const RPC_PAYLOAD_DIAGNOSTIC_SAMPLE_INTERVAL := 64
const HOST_STARTUP_SNAPSHOT_GRACE_SECONDS := 0.5
const PLAYER_DELTA_KEYFRAME_INTERVAL_SECONDS := 0.5
const ENEMY_DELTA_KEYFRAME_INTERVAL_SECONDS := 0.5
## 协议 v9 仍使用“上一发送状态”作为 delta 基线。只有连续参与每次发送的
## 接收端才能共享这一个负数命名空间；任何缺席者恢复时必须先随全 cohort 收到 full。
const SHARED_SNAPSHOT_COHORT_ID := -1
const ENEMY_ACTION_SNAPSHOT_REORDER_TOLERANCE_SECONDS := 0.075
const ENEMY_SNAPSHOT_CHUNK_MAX_ENTITIES := 56
const ENEMY_HIGH_PRESSURE_THRESHOLD := 200
const ENEMY_HIGH_PRESSURE_SNAPSHOT_HZ := 20
const COMBAT_FEEDBACK_FLUSH_INTERVAL_SECONDS := 0.05
const CORN_MACHINE_GUN_BURST_FLUSH_INTERVAL_SECONDS := 0.05
const WAVE_PROGRESS_FLUSH_INTERVAL_SECONDS := 0.1
const PLANT_HEALTH_FLUSH_INTERVAL_SECONDS := 0.05
const CLIENT_PROXY_VISUAL_BUDGET_INTERVAL_SECONDS := 0.2
const CLIENT_PROXY_VISUAL_BUDGET_MARGIN := 192.0
# Proxies outside the expanded camera rectangle have no visible transform to
# smooth. Keep their logical snapshots intact, but sample/apply them at 15 Hz.
# A deterministic per-net-id phase spreads the work instead of producing one
# large interpolation burst every fourth 60 Hz render frame.
const CLIENT_OFFSCREEN_ENEMY_INTERPOLATION_HZ := 15.0
const CLIENT_OFFSCREEN_ENEMY_INTERPOLATION_PHASE_COUNT := 64
const COMBAT_FEEDBACK_MAX_RECORDS_PER_PACKET := 40
# v9 plant records carry 41 raw packed bytes before RPC/ENet framing. Twenty-four
# records stay near 984 bytes and below the project's 1200-byte packet budget.
const PLANT_HEALTH_MAX_RECORDS_PER_PACKET := 24
const CORN_MACHINE_GUN_BURST_MAX_RECORDS_PER_PACKET := 32
const ENEMY_SPAWN_BATCH_MAX_RECORDS := 16
const ENEMY_TERMINAL_DEFEATED := 0
const ENEMY_TERMINAL_ESCAPED := 1
const ENEMY_TERMINAL_REMOVED := 2
const MULTIPLAYER_TEAM_PLANT_LIMIT := 256
const CLIENT_PENDING_PLANT_HEALTH_MAX_ENTRIES := MULTIPLAYER_TEAM_PLANT_LIMIT
const CLIENT_REMOVED_PLANT_TOMBSTONE_MAX_ENTRIES := MULTIPLAYER_TEAM_PLANT_LIMIT * 2
const PLANT_PLACEMENT_RATE_PER_SECOND := 4.0
const PLANT_PLACEMENT_RATE_BURST := 8.0
const WAREHOUSE_INTERACTION_MAX_DISTANCE := 48.0
const WAREHOUSE_TRANSACTION_RATE_PER_SECOND := 12.0
const WAREHOUSE_TRANSACTION_RATE_BURST := 20.0
const WAREHOUSE_SNAPSHOT_REQUEST_RATE_PER_SECOND := 2.0
const WAREHOUSE_SNAPSHOT_REQUEST_RATE_BURST := 4.0
const WAREHOUSE_TRANSACTION_RESULT_CACHE_SIZE := 256
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

@onready var net_manager: Node = get_node("/root/NetManager")
@onready var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore
@onready var public_room_keepalive_request: HTTPRequest = $PublicRoomKeepaliveRequest

var snapshot_mgr := SnapshotManager.new()
var _runtime_scene_cache: Dictionary = {}
var _projectile_default_parameter_cache: Dictionary[StringName, Dictionary] = {}
var _agave_cannonball_scene: PackedScene = null
var _linglan_sakura_bullet_scene: PackedScene = null
var _linglan_skill2_config: Resource = null
var _linglan_skill2_rocket_scene: PackedScene = null
var _collectible_sakura_rocket_scene: PackedScene = null
var _linglan_skill3_config: Resource = null
var _linglan_skill3_orb_scene: PackedScene = null
var _linglan_skill4_config: Resource = null
var _linglan_skill4_orb_scene: PackedScene = null
var _linglan_skill4_orb_script: Script = null
# Client-view only: remote player visual timeline. Host gameplay never reads this.
var player_visual_interpolators: Dictionary = {}
var enemy_interpolators: Dictionary = {}
var _stale_enemy_interpolator_ids: Array[int] = []
var game: GameRuntimeBase = null
var input_sequence: int = 0
var _net_time_origin: float = 0.0
var _net_enemies: Dictionary = {}
var _enemy_spawn_snapshot_times: Dictionary = {}
var _has_host_time_offset: bool = false
var _host_to_client_time_offset: float = 0.0
var _has_sent_input: bool = false
var _last_sent_move_input: Vector2 = Vector2.ZERO
var _last_sent_shoot_input: Vector2 = Vector2.ZERO
var _input_frames_since_last_send: int = _NetConstants.INPUT_KEEPALIVE_INTERVAL_FRAMES
var _local_dash_request_sequence: int = 0
var _pending_dash_request_sequence: int = 0
var _pending_dash_direction: Vector2 = Vector2.ZERO
var _pending_dash_start_move_input: Vector2 = Vector2.ZERO
var _pending_dash_input_packets: int = 0
var _local_tiyi_activation_request_id: int = 0
var _local_hoe_action_request_id: int = 0
var _last_player_state_sequences: Dictionary = {}
var _last_dash_request_sequences: Dictionary = {}
var _last_dash_confirmed_sequences: Dictionary = {}
var _last_dash_accepted_times: Dictionary = {}
var _player_character_mismatch_warnings: Dictionary = {}
var _hoe_action_sequences_by_peer: Dictionary = {}
var _last_hoe_action_request_ids: Dictionary = {}
var _tiyi_activation_sequences_by_peer: Dictionary = {}
var _active_tiyi_activations_by_peer: Dictionary = {}
var _tiyi_target_ids_by_peer: Dictionary = {}
var _pending_tiyi_target_updates: Dictionary = {}
var _last_tiyi_activation_seen_by_peer: Dictionary = {}
var _accepted_player_state_positions: Dictionary = {}
var _accepted_player_state_times: Dictionary = {}
var _host_latest_client_player_snapshot_states: Dictionary = {}
var _next_projectile_sequence: int = 1
var _known_projectiles: Dictionary = {}
var _projectile_records: Dictionary = {}
var _stale_projectile_record_ids: Array[int] = []
var _processed_enemy_hit_ids: Dictionary = {}
var _processed_player_hit_ids: Dictionary = {}
var _next_collectible_effect_event_id: int = 1
var _processed_collectible_effect_event_ids: Dictionary = {}
var _host_player_snapshot_sequence: int = 0
var _host_enemy_snapshot_batch_sequence: int = 0
var _host_enemy_snapshot_live_ids: Dictionary = {}
var _player_health_revisions: Dictionary = {}
var _local_player_hit_revision: int = 0
var _dead_player_revive_times: Dictionary = {}
var _dead_player_revive_last_seconds: Dictionary = {}
var _recent_event_prune_time_left: float = RECENT_EVENT_PRUNE_INTERVAL_SECONDS
var _snapshot_packet_warn_time_left: float = 0.0
var _host_startup_snapshot_grace_time_left: float = 0.0
var _client_host_game_ready: bool = false
var _client_has_received_flow_state: bool = false
var _runtime_state_requested: bool = false
var _max_player_snapshot_packet_bytes: int = 0
var _max_enemy_snapshot_packet_bytes: int = 0
var _large_player_snapshot_packet_count: int = 0
var _large_enemy_snapshot_packet_count: int = 0
var _enemy_snapshot_payload_bytes_total: int = 0
var _enemy_snapshot_packet_count: int = 0
var _enemy_snapshot_batch_count: int = 0
var _enemy_snapshot_completed_batch_count: int = 0
var _enemy_snapshot_incomplete_batch_evict_count: int = 0
var _enemy_snapshot_stale_chunk_count: int = 0
var _last_player_keyframe_time_by_peer: Dictionary = {}
var _last_enemy_keyframe_time_by_peer: Dictionary = {}
var _player_snapshot_cohort_peers: Dictionary = {}
var _enemy_snapshot_cohort_peers: Dictionary = {}
# Session-lifetime encode work counters. Peer detach/rejoin does not reset them;
# returning to the lobby does, and a new MpGame instance always starts at zero.
var _player_snapshot_encode_count: int = 0
var _enemy_snapshot_chunk_encode_count: int = 0
var _last_plant_placement_request_ids: Dictionary = {}
var _plant_placement_rate_buckets: Dictionary = {}
var _client_projectile_request_rate_buckets: Dictionary = {}
var _warehouse_transaction_rate_buckets: Dictionary = {}
var _warehouse_snapshot_request_rate_buckets: Dictionary = {}
var _terrain_snapshot_request_rate_buckets: Dictionary = {}
var _warehouse_transaction_results_by_peer: Dictionary = {}
var _warehouse_transaction_started_usec: Dictionary = {}
var _pending_warehouse_snapshots: Dictionary = {}
var _luoxi_offer_states_by_peer: Dictionary = {}
var _luoxi_offer_revision_counters: Dictionary = {}
var _pending_enemy_snapshot_batches: Dictionary = {}
var _last_completed_enemy_snapshot_batch_id: int = 0
var _latest_enemy_snapshot_batch_seen: int = 0
var _current_enemy_snapshot_hz: int = _NetConstants.ENEMY_SNAPSHOT_HZ
var _pending_enemy_damage_feedback: Dictionary = {}
var _combat_feedback_flush_time_left: float = COMBAT_FEEDBACK_FLUSH_INTERVAL_SECONDS
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
var _pending_wave_progress: Dictionary = {}
var _wave_progress_flush_time_left: float = WAVE_PROGRESS_FLUSH_INTERVAL_SECONDS
var _client_proxy_visual_budget_time_left: float = 0.0
var _offscreen_enemy_proxy_count: int = 0
var _offscreen_enemy_interpolation_slots: Dictionary = {}
var _last_applied_remote_enemy_count: int = -1
var _pending_enemy_spawns: Array[Dictionary] = []
var _host_terminal_enemy_ids: Dictionary = {}
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


func _ready() -> void:
	_net_time_origin = Time.get_ticks_msec() / 1000.0
	_revive_random_generator.randomize()
	_luoxi_offer_random_generator.randomize()
	set_multiplayer_authority(_get_host_peer_id())
	if not net_manager.connection_state_changed.is_connected(_on_connection_state_changed):
		net_manager.connection_state_changed.connect(_on_connection_state_changed)
	if not net_manager.player_left.is_connected(_on_net_player_left):
		net_manager.player_left.connect(_on_net_player_left)
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
	_report_game_loaded_when_prepared()


func _exit_tree() -> void:
	if net_manager != null and net_manager.connection_state_changed.is_connected(_on_connection_state_changed):
		net_manager.connection_state_changed.disconnect(_on_connection_state_changed)
	if net_manager != null and net_manager.player_left.is_connected(_on_net_player_left):
		net_manager.player_left.disconnect(_on_net_player_left)
	if game != null and game.return_to_lobby_requested.is_connected(_on_game_return_to_lobby_requested):
		game.return_to_lobby_requested.disconnect(_on_game_return_to_lobby_requested)
	if public_room_keepalive_request != null:
		if public_room_keepalive_request.request_completed.is_connected(_on_public_room_keepalive_completed):
			public_room_keepalive_request.request_completed.disconnect(_on_public_room_keepalive_completed)
		if public_room_keepalive_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
			public_room_keepalive_request.cancel_request()
	snapshot_mgr.reset_delta_cache()
	_player_snapshot_cohort_peers.clear()
	_enemy_snapshot_cohort_peers.clear()
	_pending_enemy_snapshot_batches.clear()
	_host_enemy_snapshot_live_ids.clear()
	_processed_collectible_effect_event_ids.clear()
	_pending_enemy_damage_feedback.clear()
	_pending_corn_machine_gun_burst_visuals.clear()
	_pending_corn_machine_gun_burst_action_ids.clear()
	_pending_corn_machine_gun_burst_directions.clear()
	_pending_corn_machine_gun_burst_host_times.clear()
	_pending_plant_health_updates.clear()
	_clear_remote_plant_health_state()
	_pending_wave_progress.clear()
	_pending_enemy_spawns.clear()
	_host_terminal_enemy_ids.clear()
	_offscreen_enemy_interpolation_slots.clear()
	_pending_terrain_snapshot_batches.clear()
	_terrain_snapshot_request_rate_buckets.clear()
	_client_projectile_request_rate_buckets.clear()
	_terrain_snapshot_repair_watchdog_time_left = 0.0
	_luoxi_offer_states_by_peer.clear()
	_luoxi_offer_revision_counters.clear()
	_warehouse_transaction_started_usec.clear()
	_public_room_keepalive_in_flight = false


func _physics_process(delta: float) -> void:
	if int(net_manager.connection_state) != STATE_IN_GAME:
		return
	_update_recent_event_cache_prune(delta)
	_update_snapshot_packet_warning_timer(delta)
	_update_batched_network_events(delta)
	var frame: int = net_manager.get_physics_frame_count()
	if net_manager.is_host():
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


func is_runtime_preparation_complete() -> bool:
	return game != null and game.is_runtime_preparation_complete()


func get_runtime_preparation_progress() -> Dictionary:
	if game == null:
		return {"stage": "正在创建多人战场", "completed": 0, "total": 1}
	return game.get_runtime_preparation_progress()


func _process(delta: float) -> void:
	_update_public_room_keepalive(delta)
	if net_manager.is_client() or net_manager.is_host():
		_client_interpolate_entities()
	if net_manager.is_client() and game != null:
		_update_terrain_snapshot_repair_watchdog(delta)
		_update_client_proxy_visual_budget(delta)
		var remote_enemy_count := _net_enemies.size()
		if remote_enemy_count != _last_applied_remote_enemy_count:
			_last_applied_remote_enemy_count = remote_enemy_count
			game.apply_remote_enemy_count(remote_enemy_count)


func _update_client_proxy_visual_budget(delta: float) -> void:
	_client_proxy_visual_budget_time_left = maxf(
		_client_proxy_visual_budget_time_left - maxf(delta, 0.0),
		0.0
	)
	if _client_proxy_visual_budget_time_left > 0.0 or game == null:
		return
	_client_proxy_visual_budget_time_left = CLIENT_PROXY_VISUAL_BUDGET_INTERVAL_SECONDS
	var viewport := game.get_viewport()
	var camera: Camera2D = null
	if viewport != null:
		camera = viewport.get_camera_2d()
	if camera == null:
		_offscreen_enemy_proxy_count = 0
		for enemy_net_id_variant in _net_enemies:
			var enemy_variant: Variant = _net_enemies.get(enemy_net_id_variant)
			var uncullable_enemy := enemy_variant as Enemy
			if uncullable_enemy != null and is_instance_valid(uncullable_enemy):
				uncullable_enemy.set_multiplayer_proxy_visual_active(true)
		return
	var viewport_size := viewport.get_visible_rect().size
	var safe_zoom := Vector2(
		maxf(absf(camera.zoom.x), 0.001),
		maxf(absf(camera.zoom.y), 0.001)
	)
	var visible_world_size := Vector2(
		viewport_size.x / safe_zoom.x,
		viewport_size.y / safe_zoom.y
	)
	var margin_vector := Vector2.ONE * CLIENT_PROXY_VISUAL_BUDGET_MARGIN
	var active_rect := Rect2(
		camera.get_screen_center_position() - visible_world_size * 0.5 - margin_vector,
		visible_world_size + margin_vector * 2.0
	)
	var offscreen_count := 0
	for enemy_net_id_variant in _net_enemies:
		var enemy_variant: Variant = _net_enemies.get(enemy_net_id_variant)
		var enemy := enemy_variant as Enemy
		if enemy == null or not is_instance_valid(enemy):
			continue
		var visual_active := active_rect.has_point(enemy.global_position)
		enemy.set_multiplayer_proxy_visual_active(visual_active)
		if not visual_active:
			offscreen_count += 1
	_offscreen_enemy_proxy_count = offscreen_count


func request_multiplayer_upgrade(stat_type: int) -> void:
	if net_manager.is_host():
		_apply_upgrade_for_peer(_get_local_peer_id(), stat_type)
	else:
		net_upgrade_selected.rpc_id(_get_host_peer_id(), stat_type)


func request_multiplayer_inventory_item_use(slot_index: int) -> void:
	var peer_id := _get_local_peer_id()
	var expected_revision := run_state.get_inventory_revision_for_peer(peer_id)
	if net_manager.is_host():
		_apply_inventory_item_use_for_peer(peer_id, slot_index, expected_revision)
	else:
		net_inventory_item_use_requested.rpc_id(
			_get_host_peer_id(),
			slot_index,
			expected_revision
		)


func request_multiplayer_inventory_item_discard(slot_index: int) -> void:
	var peer_id := _get_local_peer_id()
	var expected_revision := run_state.get_inventory_revision_for_peer(peer_id)
	if net_manager.is_host():
		_apply_inventory_item_discard_for_peer(peer_id, slot_index, expected_revision)
	else:
		net_inventory_item_discard_requested.rpc_id(
			_get_host_peer_id(),
			slot_index,
			expected_revision
		)


func request_multiplayer_skill1_purchase() -> void:
	if net_manager.is_host():
		_apply_skill1_purchase_for_peer(_get_local_peer_id())
	else:
		net_skill1_purchase_requested.rpc_id(_get_host_peer_id())


func request_multiplayer_start_wave() -> void:
	if game == null or not game.supports_tower_defense():
		return
	if net_manager.is_host():
		game.request_tower_defense_wave_start(_get_local_peer_id())
	else:
		net_tower_defense_start_wave_requested.rpc_id(_get_host_peer_id())


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


func has_luoxi_collectible_claimed(peer_id: int) -> bool:
	if game == null:
		return false
	return game.has_luoxi_collectible_claimed(peer_id)


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
	if net_manager.is_host():
		_apply_cheat_xirang_for_peer(_get_local_peer_id())
	else:
		net_cheat_xirang_requested.rpc_id(_get_host_peer_id())


func request_debug_collectible(config_path: String) -> void:
	if net_manager.is_host():
		_apply_debug_collectible_for_peer(_get_local_peer_id(), config_path)
	else:
		net_debug_collectible_requested.rpc_id(_get_host_peer_id(), config_path)


func _on_local_plant_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i
) -> void:
	if game == null or not game.supports_tower_defense():
		return
	if net_manager.is_host():
		_handle_authoritative_plant_placement_request(
			_get_local_peer_id(),
			request_id,
			plant_id,
			anchor
		)
	elif net_manager.is_client():
		net_plant_placement_requested.rpc_id(
			_get_host_peer_id(),
			request_id,
			String(plant_id),
			anchor
		)


func _handle_authoritative_plant_placement_request(
	requester_peer_id: int,
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i
) -> void:
	if not net_manager.is_host() or game == null or not game.supports_tower_defense():
		return
	var last_request_id := int(_last_plant_placement_request_ids.get(requester_peer_id, 0))
	if request_id <= last_request_id:
		_send_plant_placement_rejected(requester_peer_id, request_id, &"stale_request")
		return
	_last_plant_placement_request_ids[requester_peer_id] = request_id
	if not _consume_peer_rate_token(
		_plant_placement_rate_buckets,
		requester_peer_id,
		PLANT_PLACEMENT_RATE_PER_SECOND,
		PLANT_PLACEMENT_RATE_BURST
	):
		_send_plant_placement_rejected(requester_peer_id, request_id, &"rate_limited")
		return
	if _get_authoritative_team_plant_count() >= MULTIPLAYER_TEAM_PLANT_LIMIT:
		_send_plant_placement_rejected(requester_peer_id, request_id, &"team_limit_reached")
		return
	game.request_multiplayer_plant_placement(
		requester_peer_id,
		request_id,
		plant_id,
		anchor
	)


func _consume_peer_rate_token(
	buckets: Dictionary,
	peer_id: int,
	rate_per_second: float,
	burst: float
) -> bool:
	if peer_id <= 0 or rate_per_second <= 0.0 or burst <= 0.0:
		return false
	var now := _get_net_time()
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


func _get_authoritative_team_plant_count() -> int:
	if game == null or not game.supports_tower_defense():
		return 0
	var tower_defense_game := game as GameTowerDefense
	if tower_defense_game == null or tower_defense_game.plant_system == null:
		# A tower-defense Host without its authoritative registry must fail closed;
		# accepting placements here would silently bypass the shared team limit.
		return MULTIPLAYER_TEAM_PLANT_LIMIT
	return tower_defense_game.plant_system.plants_by_net_id.size()


func broadcast_plant_projectile_visual(
	_plant_net_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	speed: float,
	explosion_radius: float,
	lifetime: float
) -> void:
	if (
		not net_manager.is_host()
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


func queue_corn_machine_gun_burst_visual(
	plant_net_id: int,
	action_id: int,
	direction: Vector2
) -> void:
	if (
		not is_inside_tree()
		or not net_manager.is_host()
		or game == null
		or plant_net_id <= 0
		or action_id <= 0
		or not _is_finite_vector2(direction)
		or direction.length_squared() <= 0.001
	):
		return
	var corn := game.get_multiplayer_plant_node(plant_net_id)
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
	if not net_manager.is_host() or game == null or enemy == null or damage <= 0:
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


func _configure_warehouse_network(plant: PlantDefense, snapshot_ready: bool) -> void:
	var warehouse := plant as OakWarehouse
	if warehouse == null or game == null:
		return
	var net_id := int(warehouse.get_meta("net_id", warehouse.warehouse_net_id))
	if net_id <= 0:
		return
	warehouse.configure_multiplayer_storage(
		net_id,
		_get_local_peer_id(),
		snapshot_ready
	)
	var callback := _on_warehouse_storage_command_requested.bind(warehouse)
	if not warehouse.storage_command_requested.is_connected(callback):
		warehouse.storage_command_requested.connect(callback)
	var snapshot_callback := _on_warehouse_storage_snapshot_requested.bind(warehouse)
	if not warehouse.storage_snapshot_requested.is_connected(snapshot_callback):
		warehouse.storage_snapshot_requested.connect(snapshot_callback)
	if _pending_warehouse_snapshots.has(net_id):
		warehouse.apply_storage_snapshot(
			_pending_warehouse_snapshots.get(net_id, {}) as Dictionary
		)
		_pending_warehouse_snapshots.erase(net_id)
	if net_manager.is_client() and not warehouse.multiplayer_storage_snapshot_ready:
		warehouse.request_multiplayer_storage_snapshot()


func _on_warehouse_storage_command_requested(
	command: Dictionary,
	warehouse: OakWarehouse
) -> void:
	if warehouse == null or not is_instance_valid(warehouse):
		return
	var request_id := int(command.get("request_id", 0))
	if request_id > 0:
		_warehouse_transaction_started_usec[
			_get_warehouse_transaction_metric_key(
				int(command.get("warehouse_net_id", 0)),
				request_id
			)
		] = Time.get_ticks_usec()
	if net_manager.is_host():
		_apply_authoritative_warehouse_command(_get_local_peer_id(), command)
	elif net_manager.is_client():
		net_warehouse_command_requested.rpc_id(_get_host_peer_id(), command)


func _on_warehouse_storage_snapshot_requested(
	warehouse_net_id: int,
	warehouse: OakWarehouse
) -> void:
	if warehouse == null or not is_instance_valid(warehouse) or warehouse_net_id <= 0:
		return
	if net_manager.is_host():
		warehouse.apply_storage_snapshot(warehouse.export_storage_snapshot())
	elif net_manager.is_client():
		net_warehouse_snapshot_requested.rpc_id(
			_get_host_peer_id(),
			warehouse_net_id
		)


func _get_warehouse_transaction_metric_key(
	warehouse_net_id: int,
	request_id: int
) -> String:
	return "%d:%d" % [warehouse_net_id, request_id]


func _apply_authoritative_warehouse_command(peer_id: int, raw_command: Dictionary) -> void:
	if not net_manager.is_host() or game == null or peer_id <= 0:
		return
	var command := raw_command.duplicate(true)
	command["peer_id"] = peer_id
	var request_id := OakWarehouseProtocolScript.get_int_field(command, "request_id", 0)
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
	var warehouse := game.get_multiplayer_plant_node(warehouse_net_id) as OakWarehouse
	var player_node := game.get_player_for_peer(peer_id)
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
	elif not _consume_peer_rate_token(
		_warehouse_transaction_rate_buckets,
		peer_id,
		WAREHOUSE_TRANSACTION_RATE_PER_SECOND,
		WAREHOUSE_TRANSACTION_RATE_BURST
	):
		rejection_reason = &"rate_limited"
	else:
		result = warehouse.apply_transfer_command(command, run_state)
	if result.is_empty():
		result = OakWarehouseProtocolScript.make_result(
			command,
			false,
			rejection_reason,
			run_state.get_inventory_revision_for_peer(peer_id),
			warehouse.get_storage_revision() if warehouse != null else 0
		)
		result["inventory_snapshot"] = run_state.export_inventory_snapshot_for_peer(peer_id)
		if warehouse != null:
			result["storage_snapshot"] = warehouse.export_storage_snapshot()
	_cache_warehouse_transaction_result(peer_id, warehouse_net_id, request_id, result)
	if bool(result.get("success", false)):
		_broadcast_inventory_snapshot(peer_id)
		_broadcast_warehouse_snapshot(warehouse)
	_send_warehouse_command_result(peer_id, result)


func _is_authoritative_nearest_warehouse(
	player_node: Player,
	requested_warehouse: OakWarehouse
) -> bool:
	if player_node == null or requested_warehouse == null:
		return false
	var maximum_distance_squared := (
		WAREHOUSE_INTERACTION_MAX_DISTANCE * WAREHOUSE_INTERACTION_MAX_DISTANCE
	)
	var requested_distance := player_node.global_position.distance_squared_to(
		requested_warehouse.global_position
	)
	if requested_distance > maximum_distance_squared:
		return false
	var nearest: OakWarehouse = null
	var nearest_distance := INF
	var nearest_net_id := 0
	for plant_snapshot in game.get_multiplayer_plant_snapshots():
		var net_id := int(plant_snapshot.get("net_id", 0))
		var warehouse := game.get_multiplayer_plant_node(net_id) as OakWarehouse
		if warehouse == null or not is_instance_valid(warehouse) or warehouse.is_dead:
			continue
		var distance := player_node.global_position.distance_squared_to(warehouse.global_position)
		if distance > maximum_distance_squared:
			continue
		if distance < nearest_distance or (is_equal_approx(distance, nearest_distance) and net_id < nearest_net_id):
			nearest = warehouse
			nearest_distance = distance
			nearest_net_id = net_id
	return nearest == requested_warehouse


func _get_cached_warehouse_transaction_result(
	peer_id: int,
	warehouse_net_id: int,
	request_id: int
) -> Dictionary:
	if warehouse_net_id <= 0 or request_id <= 0:
		return {}
	var peer_cache := _warehouse_transaction_results_by_peer.get(peer_id, {}) as Dictionary
	var cache_key := _get_warehouse_transaction_metric_key(warehouse_net_id, request_id)
	return (peer_cache.get(cache_key, {}) as Dictionary).duplicate(true)


func _cache_warehouse_transaction_result(
	peer_id: int,
	warehouse_net_id: int,
	request_id: int,
	result: Dictionary
) -> void:
	if peer_id <= 0 or warehouse_net_id <= 0 or request_id <= 0:
		return
	var peer_cache := _warehouse_transaction_results_by_peer.get(peer_id, {}) as Dictionary
	var cache_key := _get_warehouse_transaction_metric_key(warehouse_net_id, request_id)
	peer_cache[cache_key] = result.duplicate(true)
	while peer_cache.size() > WAREHOUSE_TRANSACTION_RESULT_CACHE_SIZE:
		peer_cache.erase(peer_cache.keys()[0])
	_warehouse_transaction_results_by_peer[peer_id] = peer_cache


func _send_warehouse_command_result(peer_id: int, result: Dictionary) -> void:
	if peer_id == _get_local_peer_id():
		net_warehouse_command_result(result)
	elif net_manager.is_peer_send_ready(peer_id):
		net_warehouse_command_result.rpc_id(peer_id, result)


func _broadcast_inventory_snapshot(peer_id: int) -> void:
	var snapshot := run_state.export_inventory_snapshot_for_peer(peer_id)
	_rpc_to_connected_clients(&"net_inventory_snapshot", [peer_id, snapshot])


func _broadcast_warehouse_snapshot(warehouse: OakWarehouse) -> void:
	if warehouse == null or not is_instance_valid(warehouse):
		return
	_rpc_to_connected_clients(
		&"net_warehouse_storage_snapshot",
		[warehouse.warehouse_net_id, warehouse.export_storage_snapshot()]
	)


func is_client_view_runtime() -> bool:
	if game != null:
		return int(game.runtime_mode) == GAME_RUNTIME_CLIENT_VIEW
	return net_manager != null and net_manager.is_client()


func _setup_game(mode: int) -> bool:
	var game_mode := int(net_manager.get("current_game_mode"))
	var game_scene_path := (
		TOWER_DEFENSE_GAME_SCENE_PATH
		if game_mode == NetManagerStore.GameMode.TOWER_DEFENSE
		else STANDARD_GAME_SCENE_PATH
	)
	var game_scene := load(game_scene_path) as PackedScene
	if game_scene == null:
		push_error("MpGame: 无法加载所选多人游戏场景：%s" % game_scene_path)
		return false
	game = game_scene.instantiate() as GameRuntimeBase
	if game == null:
		push_error("MpGame: 无法实例化所选多人游戏场景。")
		return false
	game.defer_runtime_activation()

	var local_peer_id: int = _get_local_peer_id()
	if local_peer_id <= 0 and net_manager.is_host():
		local_peer_id = _get_host_peer_id()
	game.configure_multiplayer(
		mode,
		local_peer_id,
		net_manager.connected_players,
		net_manager.call("get_player_character_map") as Dictionary
	)
	if net_manager.is_host():
		game.multiplayer_enemy_spawned.connect(_on_host_enemy_spawned)
		game.multiplayer_enemy_defeated.connect(_on_host_enemy_defeated)
		game.multiplayer_enemy_removed.connect(_on_host_enemy_removed)
		game.multiplayer_enemy_escaped.connect(_on_host_enemy_escaped)
		game.multiplayer_pickup_spawned.connect(_on_host_pickup_spawned)
		game.multiplayer_pickup_collected.connect(_on_host_pickup_collected)
		game.multiplayer_pickup_removed.connect(_on_host_pickup_removed)
		game.multiplayer_merchant_active_changed.connect(_on_host_merchant_active_changed)
		game.multiplayer_flow_state_changed.connect(_on_host_flow_state_changed)
		game.multiplayer_boss_started.connect(_on_host_boss_started)
		game.multiplayer_defeat_started.connect(_on_host_defeat_started)
		game.multiplayer_victory_started.connect(_on_host_victory_started)
		game.multiplayer_revive_all_requested.connect(_on_host_revive_all_requested)
		game.multiplayer_base_health_changed.connect(_on_host_base_health_changed)
		game.multiplayer_tower_defense_wave_progress_changed.connect(
			_on_host_tower_defense_wave_progress_changed
		)
		game.multiplayer_plant_spawned.connect(_on_host_plant_spawned)
		game.multiplayer_plant_placement_rejected.connect(
			_on_host_plant_placement_rejected
		)
		game.multiplayer_plant_health_changed.connect(_on_host_plant_health_changed)
		game.multiplayer_plant_damage_applied.connect(_on_host_plant_damage_applied)
		game.multiplayer_plant_healing_applied.connect(_on_host_plant_healing_applied)
		game.multiplayer_plant_removed.connect(_on_host_plant_removed)
		game.multiplayer_terrain_delta.connect(_on_host_terrain_delta)
	game.multiplayer_plant_placement_requested.connect(
		_on_local_plant_placement_requested
	)
	game.return_to_lobby_requested.connect(_on_game_return_to_lobby_requested)
	add_child(game)
	if net_manager.is_client():
		_client_has_terrain_snapshot = not game.supports_multiplayer_terrain_state()
	run_state.set_active_multiplayer_peer(local_peer_id)
	if net_manager.is_host() and game.supports_tower_defense():
		_broadcast_base_health_snapshot()
	return true


func _request_runtime_state_from_host() -> void:
	if (
		_runtime_state_requested
		or not net_manager.is_client()
		or game == null
		or not _client_host_game_ready
	):
		return
	_runtime_state_requested = true
	if game.supports_multiplayer_terrain_state():
		_client_waiting_for_terrain_snapshot = true
		_arm_terrain_snapshot_repair_watchdog()
	net_runtime_state_requested.rpc_id(
		_get_host_peer_id(),
		not _client_has_received_flow_state
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
	if game.supports_tower_defense():
		var base_snapshot := game.get_base_health_snapshot()
		if not base_snapshot.is_empty():
			net_base_health_changed.rpc_id(
				peer_id,
				int(base_snapshot.get("current_health", 0)),
				int(base_snapshot.get("maximum_health", 1)),
				int(base_snapshot.get("revision", 0))
			)
		var progress_snapshot := game.get_tower_defense_wave_progress_snapshot()
		if not progress_snapshot.is_empty():
			net_tower_defense_wave_progress_keyframe.rpc_id(
				peer_id,
				int(progress_snapshot.get("wave_number", 1)),
				int(progress_snapshot.get("defeated", 0)),
				int(progress_snapshot.get("escaped", 0)),
				int(progress_snapshot.get("resolved", 0)),
				int(progress_snapshot.get("total", 0))
			)
	if include_flow_state:
		var flow_snapshot := game.get_flow_state_snapshot()
		if not flow_snapshot.is_empty():
			net_flow_state_changed.rpc_id(
				peer_id,
				String(flow_snapshot.get("step_id", &"")),
				int(flow_snapshot.get("state", GameRuntimeBase.WaveState.PRE_WAVE)),
				int(flow_snapshot.get("countdown_seconds", 0))
			)
	_send_runtime_world_manifest_to_peer(peer_id)


func _send_live_plant_roster_to_peer(peer_id: int) -> void:
	if not game.supports_tower_defense():
		return
	for plant_snapshot in game.get_multiplayer_plant_snapshots():
		var plant_net_id := int(plant_snapshot.get("net_id", 0))
		var plant := game.get_multiplayer_plant_node(plant_net_id)
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
			net_warehouse_storage_snapshot.rpc_id(
				peer_id,
				plant_net_id,
				warehouse.export_storage_snapshot()
			)


func _send_terrain_snapshot_to_peer(peer_id: int) -> void:
	if (
		not net_manager.is_host()
		or game == null
		or peer_id <= 0
		or not game.supports_multiplayer_terrain_state()
	):
		return
	var snapshot := game.get_multiplayer_terrain_snapshot()
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
	var sorted_ids: Array[int] = []
	for net_id_variant in game.multiplayer_enemies_by_net_id.keys():
		sorted_ids.append(int(net_id_variant))
	sorted_ids.sort()
	for chunk_start in range(0, sorted_ids.size(), ENEMY_SPAWN_BATCH_MAX_RECORDS):
		var chunk_end := mini(
			chunk_start + ENEMY_SPAWN_BATCH_MAX_RECORDS,
			sorted_ids.size()
		)
		var net_ids := PackedInt32Array()
		var config_paths := PackedStringArray()
		var positions := PackedVector2Array()
		var spawn_times := PackedFloat64Array()
		for record_index in range(chunk_start, chunk_end):
			var net_id := sorted_ids[record_index]
			var enemy_variant: Variant = game.multiplayer_enemies_by_net_id.get(net_id)
			if enemy_variant == null or not is_instance_valid(enemy_variant):
				continue
			var enemy := enemy_variant as Enemy
			if enemy == null or enemy.is_dead or enemy is LinglanBoss or enemy.config == null:
				continue
			var config_path := enemy.config.resource_path
			if config_path.is_empty():
				continue
			net_ids.append(net_id)
			config_paths.append(config_path)
			positions.append(enemy.global_position)
			spawn_times.append(_get_net_time())
		if net_ids.is_empty():
			continue
		_record_outbound_rpc(
			&"net_enemy_spawned_batch",
			[net_ids, config_paths, positions, spawn_times]
		)
		net_enemy_spawned_batch.rpc_id(
			peer_id,
			net_ids,
			config_paths,
			positions,
			spawn_times
		)


func _send_live_pickup_roster_to_peer(peer_id: int) -> void:
	var sorted_ids: Array[int] = []
	for net_id_variant in game.multiplayer_pickups.keys():
		sorted_ids.append(int(net_id_variant))
	sorted_ids.sort()
	for net_id in sorted_ids:
		var pickup_variant: Variant = game.multiplayer_pickups.get(net_id)
		if pickup_variant == null or not is_instance_valid(pickup_variant):
			continue
		var pickup := pickup_variant as Pickup
		if pickup == null or pickup.config == null or pickup.config.resource_path.is_empty():
			continue
		_record_outbound_rpc(
			&"net_pickup_spawned",
			[
				net_id,
				pickup.config.resource_path,
				pickup.global_position.x,
				pickup.global_position.y,
			]
		)
		net_pickup_spawned.rpc_id(
			peer_id,
			net_id,
			pickup.config.resource_path,
			pickup.global_position.x,
			pickup.global_position.y
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
	if game.supports_tower_defense():
		for plant_snapshot in game.get_multiplayer_plant_snapshots():
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
	var enemy_count := 0
	if game != null:
		enemy_count = game.multiplayer_enemies_by_net_id.size()
	var target_hz := (
		ENEMY_HIGH_PRESSURE_SNAPSHOT_HZ
		if enemy_count >= ENEMY_HIGH_PRESSURE_THRESHOLD
		else _NetConstants.ENEMY_SNAPSHOT_HZ
	)
	return maxi(roundi(float(_NetConstants.HOST_PHYSICS_HZ) / float(target_hz)), 1)


func _host_broadcast_player_snapshots(client_peer_ids: Array[int] = []) -> void:
	if client_peer_ids.is_empty():
		client_peer_ids = _get_connected_client_peer_ids()
		_sync_snapshot_cohort_readiness(client_peer_ids)
	if client_peer_ids.is_empty():
		return
	var states: Array[SnapshotManager.PlayerState] = game.collect_player_snapshot_states()
	if states.is_empty():
		return
	_apply_latest_client_player_snapshot_states(states)
	_host_player_snapshot_sequence += 1
	for state in states:
		state.sequence = _host_player_snapshot_sequence
	var snapshot_time := _get_net_time()
	var force_keyframe := _snapshot_cohort_requires_keyframe(
		_player_snapshot_cohort_peers,
		_last_player_keyframe_time_by_peer,
		client_peer_ids,
		snapshot_time,
		PLAYER_DELTA_KEYFRAME_INTERVAL_SECONDS
	)
	var data := snapshot_mgr.encode_player_snapshots_for_cohort(
		SHARED_SNAPSHOT_COHORT_ID,
		states,
		force_keyframe
	)
	_player_snapshot_encode_count += 1
	_commit_snapshot_cohort_send(
		_player_snapshot_cohort_peers,
		_last_player_keyframe_time_by_peer,
		client_peer_ids,
		snapshot_time,
		force_keyframe
	)
	for peer_id in client_peer_ids:
		_record_snapshot_packet_size(&"player", data.size(), states.size())
		_rpc_receive_player_snapshot.rpc_id(peer_id, snapshot_time, data)


func _apply_latest_client_player_snapshot_states(states: Array[SnapshotManager.PlayerState]) -> void:
	if _host_latest_client_player_snapshot_states.is_empty():
		return
	for state in states:
		if state == null or state.is_dead:
			continue
		var latest_variant: Variant = _host_latest_client_player_snapshot_states.get(state.peer_id)
		if latest_variant == null:
			continue
		var latest := latest_variant as Dictionary
		if latest.is_empty():
			continue
		state.position = latest["position"] as Vector2
		state.velocity = latest["velocity"] as Vector2
		state.facing = int(latest["facing"])
		state.anim_state = int(latest["anim_state"])


func _host_broadcast_enemy_snapshots(client_peer_ids: Array[int] = []) -> void:
	if client_peer_ids.is_empty():
		client_peer_ids = _get_connected_client_peer_ids()
		_sync_snapshot_cohort_readiness(client_peer_ids)
	if client_peer_ids.is_empty():
		return
	var states: Array[SnapshotManager.EnemyState] = game.collect_enemy_snapshot_states()
	var snapshot_time := _get_net_time()
	var snapshot_interval_frames := _get_enemy_snapshot_interval_frames()
	var snapshot_hz := maxi(
		roundi(float(_NetConstants.HOST_PHYSICS_HZ) / float(snapshot_interval_frames)),
		1
	)
	_host_enemy_snapshot_batch_sequence += 1
	var batch_id := _host_enemy_snapshot_batch_sequence
	var chunk_count := maxi(
		ceili(float(states.size()) / float(ENEMY_SNAPSHOT_CHUNK_MAX_ENTITIES)),
		1
	)
	_host_enemy_snapshot_live_ids.clear()
	for state in states:
		if state != null and state.net_id > 0:
			_host_enemy_snapshot_live_ids[state.net_id] = true
	var force_keyframe := _snapshot_cohort_requires_keyframe(
		_enemy_snapshot_cohort_peers,
		_last_enemy_keyframe_time_by_peer,
		client_peer_ids,
		snapshot_time,
		ENEMY_DELTA_KEYFRAME_INTERVAL_SECONDS
	)
	_enemy_snapshot_batch_count += client_peer_ids.size()
	for chunk_index in range(chunk_count):
		var chunk_start := chunk_index * ENEMY_SNAPSHOT_CHUNK_MAX_ENTITIES
		var chunk_end := mini(
			chunk_start + ENEMY_SNAPSHOT_CHUNK_MAX_ENTITIES,
			states.size()
		)
		var chunk_entity_count := chunk_end - chunk_start
		var data := snapshot_mgr.encode_enemy_snapshot_range_for_cohort(
			SHARED_SNAPSHOT_COHORT_ID,
			states,
			chunk_start,
			chunk_entity_count,
			force_keyframe
		)
		_enemy_snapshot_chunk_encode_count += 1
		for peer_id in client_peer_ids:
			_record_snapshot_packet_size(&"enemy", data.size(), chunk_entity_count)
			_rpc_receive_enemy_snapshot.rpc_id(
				peer_id,
				snapshot_time,
				data,
				batch_id,
				chunk_index,
				chunk_count,
				snapshot_hz
			)
	snapshot_mgr.prune_enemy_send_cohort_baseline_to_ids(
		SHARED_SNAPSHOT_COHORT_ID,
		_host_enemy_snapshot_live_ids
	)
	_commit_snapshot_cohort_send(
		_enemy_snapshot_cohort_peers,
		_last_enemy_keyframe_time_by_peer,
		client_peer_ids,
		snapshot_time,
		force_keyframe
	)


func _sync_snapshot_cohort_readiness(ready_peer_ids: Array[int]) -> void:
	var ready_lookup: Dictionary = {}
	for peer_id in ready_peer_ids:
		if peer_id > 0:
			ready_lookup[peer_id] = true
	_detach_unready_snapshot_cohort_peers(
		_player_snapshot_cohort_peers,
		_last_player_keyframe_time_by_peer,
		ready_lookup,
		true
	)
	_detach_unready_snapshot_cohort_peers(
		_enemy_snapshot_cohort_peers,
		_last_enemy_keyframe_time_by_peer,
		ready_lookup,
		false
	)


func _detach_unready_snapshot_cohort_peers(
	cohort_peers: Dictionary,
	last_keyframe_times: Dictionary,
	ready_lookup: Dictionary,
	is_player_stream: bool
) -> void:
	for peer_id_variant in cohort_peers.keys():
		var peer_id := int(peer_id_variant)
		if ready_lookup.has(peer_id):
			continue
		cohort_peers.erase(peer_id)
		last_keyframe_times.erase(peer_id)
	if not cohort_peers.is_empty():
		return
	if is_player_stream:
		snapshot_mgr.clear_player_send_baseline(SHARED_SNAPSHOT_COHORT_ID)
	else:
		snapshot_mgr.clear_enemy_send_baseline(SHARED_SNAPSHOT_COHORT_ID)


func _snapshot_cohort_requires_keyframe(
	cohort_peers: Dictionary,
	last_keyframe_times: Dictionary,
	ready_peer_ids: Array[int],
	snapshot_time: float,
	keyframe_interval_seconds: float
) -> bool:
	if ready_peer_ids.is_empty():
		return false
	if cohort_peers.size() != ready_peer_ids.size():
		return true
	for peer_id in ready_peer_ids:
		if not cohort_peers.has(peer_id) or not last_keyframe_times.has(peer_id):
			return true
		var last_keyframe_time := float(last_keyframe_times.get(peer_id, -INF))
		if snapshot_time - last_keyframe_time >= keyframe_interval_seconds:
			return true
	return false


func _commit_snapshot_cohort_send(
	cohort_peers: Dictionary,
	last_keyframe_times: Dictionary,
	ready_peer_ids: Array[int],
	snapshot_time: float,
	was_keyframe: bool
) -> void:
	cohort_peers.clear()
	for peer_id in ready_peer_ids:
		if peer_id <= 0:
			continue
		cohort_peers[peer_id] = true
		if was_keyframe:
			last_keyframe_times[peer_id] = snapshot_time


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
		if (
			net_manager.has_method("is_peer_send_ready")
			and not bool(net_manager.call("is_peer_send_ready", peer_id))
		):
			continue
		result.append(peer_id)
	return result


func _rpc_to_connected_clients(method_name: StringName, args: Array = []) -> void:
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
		"enemy_snapshot_batch_count": _enemy_snapshot_batch_count,
		"player_snapshot_encode_count": _player_snapshot_encode_count,
		"enemy_snapshot_chunk_encode_count": _enemy_snapshot_chunk_encode_count,
		"player_snapshot_cohort_size": _player_snapshot_cohort_peers.size(),
		"enemy_snapshot_cohort_size": _enemy_snapshot_cohort_peers.size(),
		"enemy_snapshot_completed_batch_count": _enemy_snapshot_completed_batch_count,
		"enemy_snapshot_incomplete_batch_evict_count": _enemy_snapshot_incomplete_batch_evict_count,
		"enemy_snapshot_stale_chunk_count": _enemy_snapshot_stale_chunk_count,
		"offscreen_enemy_proxy_count": _offscreen_enemy_proxy_count,
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


func _create_player_interpolator() -> NetInterpolator:
	return NetInterpolator.new(
		1.0 / float(_NetConstants.PLAYER_SNAPSHOT_HZ),
		_NetConstants.PLAYER_INTERPOLATION_DELAY_FACTOR,
		_NetConstants.PLAYER_MAX_EXTRAPOLATION_SECONDS
	)


func _create_enemy_interpolator() -> NetInterpolator:
	return NetInterpolator.new(
		1.0 / float(maxi(_current_enemy_snapshot_hz, 1)),
		_NetConstants.ENEMY_INTERPOLATION_DELAY_FACTOR,
		_NetConstants.ENEMY_MAX_EXTRAPOLATION_SECONDS
	)


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
	var shoot_input := _get_client_shoot_input()
	var player_node: Player = null
	if game != null:
		player_node = game.player
	if player_node == null:
		return
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
	var active_realtime_state := (
		move_input != Vector2.ZERO
		or shoot_input != Vector2.ZERO
		or player_node.velocity.length_squared() > INPUT_CHANGE_EPSILON
		or player_node.skill1_unlocked
		or player_node.invincibility_time_left > 0.0
		or player_node.has_active_multiplayer_character_state()
	)
	if not input_changed and not keepalive_due and buttons == 0 and not active_realtime_state:
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
		_pending_dash_start_move_input,
		player_node.current_health,
		player_node.max_health,
		player_node.current_xirang,
		player_node.is_dead,
		player_node.invincibility_time_left,
		player_node.skill1_unlocked,
		player_node.skill1_charge,
		player_node.skill1_charge_duration,
		player_node.get_multiplayer_form_mode(),
		player_node.get_multiplayer_shot_pattern()
	)


func _get_client_shoot_input() -> Vector2:
	var shoot_input := Input.get_vector("shoot_left", "shoot_right", "shoot_up", "shoot_down")
	if shoot_input != Vector2.ZERO:
		return shoot_input
	if game == null or game.player == null:
		return Vector2.ZERO
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return Vector2.ZERO
	return game.player.global_position.direction_to(game.player.get_global_mouse_position())


func _client_interpolate_entities() -> void:
	if game == null:
		return
	var current_time := _get_net_time()
	var local_peer_id: int = _get_client_view_local_peer_id()
	if is_client_view_runtime():
		for peer_id_variant in player_visual_interpolators:
			var peer_id := int(peer_id_variant)
			if peer_id == local_peer_id:
				continue
			var interp := player_visual_interpolators[peer_id] as NetInterpolator
			var player_node: Player = game.get_player_for_peer(peer_id)
			if interp != null and player_node != null and is_instance_valid(player_node):
				var frame_state: NetInterpolator.FrameSnapshot = interp.get_current_state(current_time)
				player_node.apply_multiplayer_snapshot_motion(
					interp.get_interpolated_position(current_time),
					interp.get_interpolated_velocity(current_time),
					frame_state.facing,
					frame_state.anim_state
				)
	_stale_enemy_interpolator_ids.clear()
	for net_id_variant in enemy_interpolators:
		var net_id := int(net_id_variant)
		var enemy_interp := enemy_interpolators.get(net_id) as NetInterpolator
		var enemy_variant: Variant = _net_enemies.get(net_id)
		if (
			enemy_interp == null
			or enemy_variant == null
			or not is_instance_valid(enemy_variant)
		):
			_stale_enemy_interpolator_ids.append(net_id)
			continue
		var enemy_node := enemy_variant as Enemy
		if enemy_node == null:
			_stale_enemy_interpolator_ids.append(net_id)
			continue
		if not _should_interpolate_enemy_proxy(net_id, enemy_node, current_time):
			continue
		var enemy_position: Vector2 = enemy_interp.get_interpolated_position(current_time)
		var enemy_velocity: Vector2 = enemy_interp.get_interpolated_velocity(current_time)
		enemy_node.apply_multiplayer_proxy_motion(enemy_position, enemy_velocity)
	# Dictionary mutation during direct iteration is unsafe. Prune invalid entries
	# only after the allocation-free traversal has completed.
	for stale_net_id in _stale_enemy_interpolator_ids:
		_get_valid_client_enemy_for_net_id(stale_net_id)
		enemy_interpolators.erase(stale_net_id)
		_offscreen_enemy_interpolation_slots.erase(stale_net_id)


func _should_interpolate_enemy_proxy(
	net_id: int,
	enemy_node: Enemy,
	current_time: float
) -> bool:
	if (
		not is_client_view_runtime()
		or enemy_node == null
		or enemy_node.multiplayer_proxy_visual_active
	):
		return true
	var interval := 1.0 / CLIENT_OFFSCREEN_ENEMY_INTERPOLATION_HZ
	var phase_index := (net_id * 37) % CLIENT_OFFSCREEN_ENEMY_INTERPOLATION_PHASE_COUNT
	var phase_offset := (
		float(phase_index)
		/ float(CLIENT_OFFSCREEN_ENEMY_INTERPOLATION_PHASE_COUNT)
		* interval
	)
	var current_slot := floori((current_time + phase_offset) / interval)
	var previous_slot := int(_offscreen_enemy_interpolation_slots.get(net_id, current_slot - 1))
	if previous_slot == current_slot:
		return false
	_offscreen_enemy_interpolation_slots[net_id] = current_slot
	return true


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _rpc_receive_player_snapshot(host_timestamp: float, data: PackedByteArray) -> void:
	if game == null:
		return
	if not is_client_view_runtime():
		return
	var snapshot_time := _map_host_timestamp_to_client_time(host_timestamp)
	var states := snapshot_mgr.decode_player_snapshots_with_baseline(data)
	var snapshot_has_full_roster := _is_complete_player_snapshot_batch(data, states.size())
	var seen_player_ids: Dictionary = {}
	for state in states:
		var player_state := state as SnapshotManager.PlayerState
		if player_state == null:
			continue
		if player_state.peer_id <= 0:
			continue
		seen_player_ids[player_state.peer_id] = true
		var player_node: Player = game.get_player_for_peer(player_state.peer_id)
		if player_node != null and is_instance_valid(player_node):
			if player_node.get_character_id() != player_state.character_id:
				_warn_player_character_snapshot_mismatch(
					player_state.peer_id,
					player_node.get_character_id(),
					player_state.character_id
				)
				continue
			_apply_player_primary_cooldown_ratio(
				player_node,
				player_state.primary_cooldown_ratio
			)
		if is_client_view_runtime() and player_state.peer_id == _get_client_view_local_peer_id():
			_apply_player_realtime_snapshot(player_node, player_state)
			continue
		if not player_visual_interpolators.has(player_state.peer_id):
			player_visual_interpolators[player_state.peer_id] = _create_player_interpolator()
		var interp := player_visual_interpolators[player_state.peer_id] as NetInterpolator
		interp.push_snapshot(
			snapshot_time,
			player_state.position,
			player_state.velocity,
			player_state.facing,
			player_state.anim_state,
			0,
			false
		)
		if player_node != null and is_instance_valid(player_node):
			_apply_player_realtime_snapshot(player_node, player_state)
	if snapshot_has_full_roster:
		_reconcile_player_roster(seen_player_ids)


func _apply_player_primary_cooldown_ratio(player_node: Player, ratio: float) -> void:
	if player_node == null or not player_node.has_method("apply_multiplayer_primary_cooldown_ratio"):
		return
	player_node.call("apply_multiplayer_primary_cooldown_ratio", clampf(ratio, 0.0, 1.0))


func _get_player_primary_cooldown_ratio(player_node: Player) -> float:
	if player_node == null or not is_instance_valid(player_node):
		return 0.0
	return clampf(player_node.get_primary_cooldown_ratio(), 0.0, 1.0)


func _apply_player_realtime_snapshot(
	player_node: Player,
	player_state: SnapshotManager.PlayerState
) -> void:
	if player_node == null or player_state == null or not is_instance_valid(player_node):
		return
	player_node.apply_multiplayer_realtime_state(
		player_state.current_health,
		player_state.max_health,
		player_state.current_xirang,
		player_state.is_dead,
		player_state.invincibility_time_left,
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


func _warn_player_character_snapshot_mismatch(
	peer_id: int,
	local_character_id: StringName,
	host_character_id: StringName
) -> void:
	if _player_character_mismatch_warnings.has(peer_id):
		return
	_player_character_mismatch_warnings[peer_id] = true
	push_warning(
		"MpGame: peer %d 角色不一致 local=%s host=%s，忽略该角色快照。"
		% [peer_id, local_character_id, host_character_id]
	)


func _is_complete_player_snapshot_batch(data: PackedByteArray, decoded_count: int) -> bool:
	if data.is_empty():
		return false
	var expected_count := int(data[0])
	return expected_count > 0 and decoded_count == expected_count


func _reconcile_player_roster(seen_player_ids: Dictionary) -> void:
	if game == null or seen_player_ids.is_empty():
		return
	if int(game.runtime_mode) != GAME_RUNTIME_CLIENT_VIEW:
		return
	var local_peer_id := _get_local_peer_id()
	if local_peer_id <= 0:
		local_peer_id = game.multiplayer_local_peer_id
	for peer_id_variant in game.peer_players.keys():
		var peer_id := int(peer_id_variant)
		if peer_id == local_peer_id:
			continue
		if seen_player_ids.has(peer_id):
			continue
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
	if game == null:
		return
	if not is_client_view_runtime():
		return
	var is_chunked_batch := batch_id > 0
	if is_chunked_batch and (chunk_count <= 0 or chunk_index < 0 or chunk_index >= chunk_count):
		return
	if is_chunked_batch and batch_id <= _last_completed_enemy_snapshot_batch_id:
		_enemy_snapshot_stale_chunk_count += 1
		return
	if is_chunked_batch and batch_id < _latest_enemy_snapshot_batch_seen:
		_enemy_snapshot_stale_chunk_count += 1
		return
	if is_chunked_batch:
		_latest_enemy_snapshot_batch_seen = maxi(_latest_enemy_snapshot_batch_seen, batch_id)
	var resolved_snapshot_hz := clampi(snapshot_hz, 1, _NetConstants.HOST_PHYSICS_HZ)
	if resolved_snapshot_hz != _current_enemy_snapshot_hz:
		_current_enemy_snapshot_hz = resolved_snapshot_hz
		for interpolator_variant in enemy_interpolators.values():
			var existing_interpolator := interpolator_variant as NetInterpolator
			if existing_interpolator != null:
				existing_interpolator.set_snapshot_interval(1.0 / float(resolved_snapshot_hz))
	var snapshot_time := _map_host_timestamp_to_client_time(host_timestamp)
	var batch: Dictionary = {}
	if is_chunked_batch:
		_prune_old_enemy_snapshot_batches(batch_id)
		batch = _pending_enemy_snapshot_batches.get(batch_id, {}) as Dictionary
		if batch.is_empty():
			batch = {
				"chunk_count": chunk_count,
				"received": {},
				"seen": {},
				"snapshot_time": snapshot_time,
			}
			_pending_enemy_snapshot_batches[batch_id] = batch
		elif int(batch.get("chunk_count", 0)) != chunk_count:
			_pending_enemy_snapshot_batches.erase(batch_id)
			return
		var received := batch["received"] as Dictionary
		if received.has(chunk_index):
			return
	var states := snapshot_mgr.decode_enemy_snapshots_with_baseline(data, not is_chunked_batch)
	var snapshot_has_full_roster := _is_complete_enemy_snapshot_batch(data, states.size())
	var seen_enemy_ids: Dictionary = {}
	if is_chunked_batch:
		seen_enemy_ids = batch["seen"] as Dictionary
	for state in states:
		var enemy_state := state as SnapshotManager.EnemyState
		if enemy_state == null:
			continue
		if enemy_state.net_id <= 0:
			continue
		seen_enemy_ids[enemy_state.net_id] = true
		if enemy_state.is_dead:
			var dead_enemy: Enemy = _get_valid_client_enemy_for_net_id(enemy_state.net_id)
			if dead_enemy != null and is_instance_valid(dead_enemy):
				dead_enemy.global_position = enemy_state.position
				_apply_enemy_network_health(dead_enemy, enemy_state.health)
			_remove_client_enemy(enemy_state.net_id, true)
			continue
		if not enemy_interpolators.has(enemy_state.net_id):
			enemy_interpolators[enemy_state.net_id] = _create_enemy_interpolator()
		var interp := enemy_interpolators[enemy_state.net_id] as NetInterpolator
		interp.push_snapshot(
			snapshot_time,
			enemy_state.position,
			enemy_state.velocity,
			0,
			0,
			enemy_state.health,
			enemy_state.is_dead
		)
		var enemy_node: Enemy = _get_valid_client_enemy_for_net_id(enemy_state.net_id)
		if enemy_node != null and is_instance_valid(enemy_node):
			_apply_enemy_network_health(enemy_node, enemy_state.health)
			enemy_node.is_dead = enemy_state.is_dead
			enemy_node.apply_multiplayer_visual_status_mask(enemy_state.visual_status_mask)
	if not is_chunked_batch:
		if snapshot_has_full_roster:
			_reconcile_enemy_roster(seen_enemy_ids, snapshot_time)
		return
	if not snapshot_has_full_roster:
		return
	var received := batch["received"] as Dictionary
	received[chunk_index] = true
	if received.size() == chunk_count:
		snapshot_mgr.prune_enemy_receive_baseline_to_ids(seen_enemy_ids)
		_enemy_snapshot_completed_batch_count += 1
		_last_completed_enemy_snapshot_batch_id = batch_id
		_discard_enemy_snapshot_batches_through(batch_id)
		_reconcile_enemy_roster(seen_enemy_ids, float(batch.get("snapshot_time", snapshot_time)))


func _prune_old_enemy_snapshot_batches(current_batch_id: int) -> void:
	for pending_batch_id_variant in _pending_enemy_snapshot_batches.keys():
		var pending_batch_id := int(pending_batch_id_variant)
		if pending_batch_id < current_batch_id - 2:
			_enemy_snapshot_incomplete_batch_evict_count += 1
			_pending_enemy_snapshot_batches.erase(pending_batch_id)


func _discard_enemy_snapshot_batches_through(completed_batch_id: int) -> void:
	for pending_batch_id_variant in _pending_enemy_snapshot_batches.keys():
		var pending_batch_id := int(pending_batch_id_variant)
		if pending_batch_id <= completed_batch_id:
			if pending_batch_id < completed_batch_id:
				_enemy_snapshot_incomplete_batch_evict_count += 1
			_pending_enemy_snapshot_batches.erase(pending_batch_id)


func _is_complete_enemy_snapshot_batch(data: PackedByteArray, decoded_count: int) -> bool:
	if data.size() < 2:
		return false
	var stream := StreamPeerBuffer.new()
	stream.data_array = data
	var expected_count := stream.get_u16()
	return decoded_count == expected_count


func _apply_enemy_network_health(enemy_node: Enemy, current_health: int) -> void:
	if enemy_node == null:
		return
	if enemy_node.has_method("apply_multiplayer_health_snapshot"):
		enemy_node.call("apply_multiplayer_health_snapshot", current_health)
	else:
		enemy_node.current_health = current_health


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
	dash_start_move_input: Vector2,
	current_health: int,
	max_health: int,
	current_xirang: int,
	is_dead: bool,
	invincibility_time_left: float,
	skill1_unlocked: bool,
	skill1_charge: float,
	skill1_charge_duration: float,
	form_mode: int,
	shot_pattern: int
) -> void:
	if not net_manager.is_host() or game == null:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	var player_node := game.get_player_for_peer(sender_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if player_node.is_dead or player_node.controls_locked:
		net_player_state_corrected.rpc_id(sender_id, player_node.global_position, player_node.velocity)
		return
	if is_dead or current_health <= 0:
		net_player_state_corrected.rpc_id(sender_id, player_node.global_position, player_node.velocity)
		return
	if not _accept_client_player_state(sender_id, sequence, reported_position, reported_velocity):
		net_player_state_corrected.rpc_id(sender_id, player_node.global_position, player_node.velocity)
		return
	var use_reload: bool = (buttons & INPUT_BUTTON_RELOAD) != 0
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
	_remember_latest_client_player_snapshot_state(
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
	if sender_id <= 0:
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
	if sender_id <= 0:
		return
	_apply_authoritative_hoe_action(sender_id, HOE_ACTION_PRIMARY, direction, request_id)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_hoe_whirlwind_requested(request_id: int = 0) -> void:
	if not net_manager.is_host() or game == null:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
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
func net_tiyi_high_noon_requested(activation_id: int) -> void:
	if not net_manager.is_host() or game == null:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0 or activation_id <= 0:
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
	if game == null or game.player == null:
		return
	game.player.global_position = corrected_position
	game.player.velocity = corrected_velocity


func _reset_player_visual_interpolator_to_state(
	peer_id: int,
	player_position: Vector2,
	player_velocity: Vector2,
	facing_id: int,
	anim_state: int
) -> void:
	if peer_id <= 0:
		return
	if not player_visual_interpolators.has(peer_id):
		player_visual_interpolators[peer_id] = _create_player_interpolator()
	var interp: NetInterpolator = player_visual_interpolators[peer_id] as NetInterpolator
	if interp == null:
		return
	interp.clear()
	interp.push_snapshot(
		_get_net_time(),
		player_position,
		player_velocity,
		facing_id,
		anim_state,
		0,
		false
	)


func _remember_latest_client_player_snapshot_state(
	peer_id: int,
	player_position: Vector2,
	player_velocity: Vector2,
	facing_id: int,
	anim_state: int
) -> void:
	if not net_manager.is_host() or peer_id <= 0:
		return
	_host_latest_client_player_snapshot_states[peer_id] = {
		"position": player_position,
		"velocity": player_velocity,
		"facing": facing_id,
		"anim_state": anim_state,
	}


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
	var projectile_id := _register_local_projectile_identity(
		projectile,
		projectile_type,
		owner_peer_id,
		damage,
		lifetime,
		pierces_enemies
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
		or owner_peer_id <= 0
		or owner_peer_id > PROJECTILE_ID_MAX_OWNER_PEER_ID
	):
		return
	# Validate every projectile lease before mutating the registries so malformed
	# callers cannot leave a partial ring. ID-space exhaustion is an unrecoverable
	# allocator failure rather than a transactional rollback case.
	for projectile in projectiles:
		if projectile == null or not is_instance_valid(projectile):
			return

	var projectile_ids := PackedInt64Array()
	for projectile_index in range(projectile_count):
		var projectile := projectiles[projectile_index]
		var projectile_id := _register_local_projectile_identity(
			projectile,
			&"linglan_skill1",
			owner_peer_id,
			damage,
			lifetime,
			false
		)
		if projectile_id <= 0:
			return
		projectile_ids.append(projectile_id)
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


func _register_local_projectile_identity(
	projectile: Node,
	projectile_type: StringName,
	owner_peer_id: int,
	damage: int,
	lifetime: float,
	pierces_enemies: bool
) -> int:
	var projectile_namespace := owner_peer_id
	if projectile_namespace <= 0:
		projectile_namespace = PROJECTILE_ID_FALLBACK_OWNER_PEER_ID
	var projectile_id := _allocate_projectile_id(
		projectile_namespace,
		net_manager != null and net_manager.is_host()
	)
	if projectile_id <= 0:
		push_error(
			"MpGame: unable to allocate projectile id for owner %d."
			% projectile_namespace
		)
		return 0
	_setup_projectile_network_identity(projectile, projectile_id, owner_peer_id, projectile_type)
	_known_projectiles[projectile_id] = projectile
	_remember_projectile_record(
		projectile_id,
		owner_peer_id,
		projectile_type,
		damage,
		lifetime,
		pierces_enemies
	)
	return projectile_id


func _allocate_projectile_id(owner_peer_id: int, host_origin: bool) -> int:
	if owner_peer_id <= 0 or owner_peer_id > PROJECTILE_ID_MAX_OWNER_PEER_ID:
		return 0
	# A zero or exhausted sequence can only occur after explicit state corruption
	# or 2^31-1 allocations (more than 69 days at 360 projectiles/s). Wrap safely
	# and skip any still-live/recent record instead of ever reusing its identity.
	if (
		_next_projectile_sequence <= 0
		or _next_projectile_sequence > PROJECTILE_ID_SEQUENCE_COUNTER_MASK
	):
		_next_projectile_sequence = 1
	var first_sequence := _next_projectile_sequence
	while true:
		var sequence_counter := _next_projectile_sequence
		_next_projectile_sequence += 1
		if _next_projectile_sequence > PROJECTILE_ID_SEQUENCE_COUNTER_MASK:
			_next_projectile_sequence = 1
		var sequence := sequence_counter
		if host_origin:
			sequence |= PROJECTILE_ID_HOST_ORIGIN_BIT
		var projectile_id := _encode_projectile_id(owner_peer_id, sequence)
		if (
			projectile_id > 0
			and not _known_projectiles.has(projectile_id)
			and not _projectile_records.has(projectile_id)
		):
			return projectile_id
		if _next_projectile_sequence == first_sequence:
			return 0
	return 0


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
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not _try_accept_client_projectile_request_identity(
		sender_id,
		projectile_id,
		owner_peer_id
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
	if not should_home or game == null:
		return 0
	var owner_player := game.get_player_for_peer(owner_peer_id) as Player
	if owner_player == null or not is_instance_valid(owner_player):
		return 0
	var target := owner_player._find_homing_bullet_target(direction)
	if target == null or not is_instance_valid(target) or target.is_dead:
		return 0
	return int(target.get_meta("net_id", 0))


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
	if _known_projectiles.has(projectile_id):
		_reconcile_predicted_projectile(
			projectile_id,
			owner_peer_id,
			StringName(projectile_type),
			direction,
			damage,
			speed,
			lifetime,
			pierces_enemies,
			target_enemy_net_id
		)
		return
	if _projectile_records.has(projectile_id):
		return
	_spawn_network_projectile(
		projectile_id,
		StringName(projectile_type),
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


func _try_accept_client_projectile_request_identity(
	sender_id: int,
	projectile_id: int,
	owner_peer_id: int
) -> bool:
	if sender_id <= 0 or owner_peer_id != sender_id:
		return false
	# Duplicate predicted-shot retries are already known and must not consume the
	# peer's budget. The origin-lane check is likewise cheaper than validating or
	# instantiating the requested projectile type.
	if _known_projectiles.has(projectile_id) or _projectile_records.has(projectile_id):
		return false
	if not _is_projectile_id_valid_for_client_owner(projectile_id, owner_peer_id):
		return false
	return _consume_peer_rate_token(
		_client_projectile_request_rate_buckets,
		sender_id,
		CLIENT_PROJECTILE_REQUEST_RATE_PER_SECOND,
		CLIENT_PROJECTILE_REQUEST_RATE_BURST
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
	if not _is_valid_linglan_skill1_ring_payload(
		projectile_ids,
		spawn_positions,
		directions,
		owner_peer_id,
		damage,
		speed,
		lifetime,
		host_fire_timestamp
	):
		return
	for projectile_index in range(projectile_ids.size()):
		var projectile_id := int(projectile_ids[projectile_index])
		if (
			_known_projectiles.has(projectile_id)
			or _projectile_records.has(projectile_id)
		):
			continue
		_spawn_network_projectile(
			projectile_id,
			&"linglan_skill1",
			owner_peer_id,
			spawn_positions[projectile_index],
			directions[projectile_index],
			damage,
			speed,
			lifetime,
			false,
			0,
			host_fire_timestamp,
			0
		)


func _reconcile_predicted_projectile(
	projectile_id: int,
	owner_peer_id: int,
	projectile_type: StringName,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	pierces_enemies: bool,
	target_enemy_net_id: int
) -> void:
	var projectile_variant: Variant = _known_projectiles.get(projectile_id)
	if projectile_variant == null or not is_instance_valid(projectile_variant):
		_known_projectiles.erase(projectile_id)
		return
	var bullet := projectile_variant as Bullet
	if bullet != null:
		bullet.setup(direction, damage, pierces_enemies)
		bullet.speed = maxf(speed, 0.0)
		bullet.max_lifetime = maxf(lifetime, 0.01)
		bullet.remaining_lifetime = minf(
			bullet.remaining_lifetime,
			bullet.max_lifetime
		)
		var homing_target: Enemy = null
		if game != null and target_enemy_net_id > 0:
			homing_target = game.get_enemy_for_net_id(target_enemy_net_id)
		bullet.setup_homing(homing_target)
	_remember_projectile_record(
		projectile_id,
		owner_peer_id,
		projectile_type,
		damage,
		lifetime,
		pierces_enemies
	)


func _spawn_network_projectile(
	projectile_id: int,
	projectile_type: StringName,
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
	var projectile := _instantiate_projectile(
		projectile_type,
		owner_peer_id,
		direction,
		damage,
		speed,
		lifetime,
		pierces_enemies,
		target_peer_id,
		target_enemy_net_id
	)
	if projectile == null:
		return
	_setup_projectile_network_identity(projectile, projectile_id, owner_peer_id, projectile_type)
	_known_projectiles[projectile_id] = projectile
	var compensation_age := _get_projectile_time_compensation_age(host_fire_timestamp, lifetime)
	_remember_projectile_record(
		projectile_id,
		owner_peer_id,
		projectile_type,
		damage,
		lifetime,
		pierces_enemies
	)
	if projectile.get_parent() == null:
		add_child(projectile)
	projectile.global_position = spawn_position
	projectile.reset_physics_interpolation()
	if compensation_age > 0.0 and projectile.has_method("simulate_compensated_motion"):
		projectile.call("simulate_compensated_motion", compensation_age)
	else:
		projectile.global_position += (
			direction.normalized() * maxf(speed, 0.0) * compensation_age
		)
	_apply_projectile_lifetime_compensation(projectile, lifetime, compensation_age)


func _get_projectile_time_compensation_age(host_fire_timestamp: float, lifetime: float) -> float:
	if host_fire_timestamp < 0.0:
		return 0.0
	var mapped_fire_time := host_fire_timestamp
	if net_manager == null or not net_manager.is_host():
		mapped_fire_time = _map_host_timestamp_to_client_time(host_fire_timestamp, false)
	var age := _get_net_time() - mapped_fire_time
	return clampf(age, 0.0, minf(PROJECTILE_TIME_COMPENSATION_MAX_SECONDS, maxf(lifetime, 0.0)))


func _apply_projectile_lifetime_compensation(
	projectile: Node,
	lifetime: float,
	compensation_age: float
) -> void:
	if projectile == null or compensation_age <= 0.0:
		return
	var remaining := maxf(lifetime - compensation_age, 0.05)
	var bullet := projectile as Bullet
	if bullet != null:
		bullet.remaining_lifetime = remaining
		return
	if projectile != null and projectile.get_script() == COLLECTIBLE_ARROW_PROJECTILE_SCRIPT:
		projectile.set("remaining_lifetime", remaining)
		return
	var capoo_bullet := projectile as CapooAK47Bullet
	if capoo_bullet != null:
		capoo_bullet.remaining_lifetime = remaining
		return
	var rpg_rocket := projectile as CapooRPGRocket
	if rpg_rocket != null:
		rpg_rocket.remaining_lifetime = remaining
		return
	var fireball := projectile as CapooMageFireball
	if fireball != null:
		fireball.remaining_lifetime = remaining
		return
	var fire_projectile := projectile as YuanshiInsectFireProjectile
	if fire_projectile != null:
		fire_projectile.remaining_lifetime = remaining
		return
	var projectile_script := projectile.get_script() as Script
	var projectile_script_path := projectile_script.resource_path if projectile_script != null else ""
	if (
		projectile_script_path == "res://scene/player/weishidaier/weishidaier_skill1_bomb.gd"
		or projectile_script_path == "res://scene/boss/linglan/linglan_skill1_sakura_bullet.gd"
		or projectile_script_path == "res://scene/boss/linglan/linglan_skill2_sakura_rocket.gd"
	):
		projectile.set("remaining_lifetime", remaining)
		return
	if (
		projectile != null
		and _linglan_skill4_orb_script != null
		and projectile.get_script() == _linglan_skill4_orb_script
	):
		projectile.set("remaining_lifetime", remaining)
		return


func _get_runtime_packed_scene(path: String) -> PackedScene:
	var cached_scene := _runtime_scene_cache.get(path) as PackedScene
	if cached_scene != null:
		return cached_scene
	var loaded_scene := load(path) as PackedScene
	if loaded_scene != null:
		_runtime_scene_cache[path] = loaded_scene
	return loaded_scene


func _acquire_or_instantiate_projectile(scene: PackedScene) -> Node:
	if scene == null:
		return null
	if has_session_object_pool_scene(scene):
		return acquire_session_object(scene, false)
	return scene.instantiate()


func _get_cached_projectile_defaults(
	projectile_type: StringName,
	scene: PackedScene
) -> Dictionary:
	var cached := _projectile_default_parameter_cache.get(projectile_type, {}) as Dictionary
	if not cached.is_empty():
		return cached
	if scene == null:
		return {}
	var projectile := scene.instantiate()
	if projectile == null:
		return {}
	var defaults := {
		"speed": float(projectile.get("speed")),
		"lifetime": float(projectile.get("max_lifetime")),
	}
	projectile.free()
	_projectile_default_parameter_cache[projectile_type] = defaults
	return defaults


func _instantiate_projectile(
	projectile_type: StringName,
	owner_peer_id: int,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	pierces_enemies: bool = false,
	target_peer_id: int = 0,
	target_enemy_net_id: int = 0
) -> Node:
	match projectile_type:
		&"player_bullet":
			var bullet_scene := _get_runtime_packed_scene(BULLET_SCENE_PATH)
			if bullet_scene == null:
				return null
			var bullet := _acquire_or_instantiate_projectile(bullet_scene) as Bullet
			if bullet == null:
				return null
			bullet.top_level = true
			bullet.setup(direction, damage, pierces_enemies)
			if game != null and target_enemy_net_id > 0:
				bullet.setup_homing(game.get_enemy_for_net_id(target_enemy_net_id))
			bullet.speed = speed
			bullet.max_lifetime = lifetime
			bullet.remaining_lifetime = lifetime
			return bullet
		TIYI_SNIPER_PROJECTILE_TYPE:
			var sniper_scene := _get_runtime_packed_scene(TIYI_SNIPER_BULLET_SCENE_PATH)
			if sniper_scene == null:
				return null
			var sniper_bullet := _acquire_or_instantiate_projectile(sniper_scene) as Bullet
			if sniper_bullet == null:
				return null
			sniper_bullet.top_level = true
			sniper_bullet.setup(direction, damage, pierces_enemies)
			if game != null and target_enemy_net_id > 0:
				sniper_bullet.setup_homing(game.get_enemy_for_net_id(target_enemy_net_id))
			sniper_bullet.speed = speed
			sniper_bullet.max_lifetime = lifetime
			sniper_bullet.remaining_lifetime = lifetime
			return sniper_bullet
		&"collectible_arrow":
			var collectible_arrow := _acquire_or_instantiate_projectile(
				COLLECTIBLE_ARROW_PROJECTILE_SCENE
			)
			if collectible_arrow == null:
				return null
			collectible_arrow.top_level = true
			collectible_arrow.call("setup", direction, damage)
			collectible_arrow.set("speed", speed)
			collectible_arrow.set("max_lifetime", lifetime)
			collectible_arrow.set("remaining_lifetime", lifetime)
			return collectible_arrow
		&"skill1_bomb":
			var bomb_scene := _get_runtime_packed_scene(SKILL1_BOMB_SCENE_PATH)
			if bomb_scene == null:
				return null
			var bomb := bomb_scene.instantiate() as Node2D
			if bomb == null:
				return null
			bomb.top_level = true
			bomb.call("setup", game.get_player_for_peer(owner_peer_id), direction, damage)
			bomb.set("speed", speed)
			bomb.set("max_lifetime", lifetime)
			bomb.set("remaining_lifetime", lifetime)
			return bomb
		&"capoo_ak47_bullet":
			var capoo_bullet := (
				_acquire_or_instantiate_projectile(CAPOO_AK47_BULLET_SCENE)
				as CapooAK47Bullet
			)
			if capoo_bullet == null:
				return null
			capoo_bullet.top_level = true
			capoo_bullet.setup(direction, damage, speed, lifetime)
			return capoo_bullet
		&"capoo_rpg_rocket":
			var rpg_rocket := (
				_acquire_or_instantiate_projectile(CAPOO_RPG_ROCKET_SCENE)
				as CapooRPGRocket
			)
			if rpg_rocket == null:
				return null
			rpg_rocket.top_level = true
			rpg_rocket.setup(direction, damage, speed, lifetime)
			return rpg_rocket
		&"capoo_mage_fireball":
			var fireball := (
				_acquire_or_instantiate_projectile(CAPOO_MAGE_FIREBALL_SCENE)
				as CapooMageFireball
			)
			if fireball == null:
				return null
			fireball.top_level = true
			fireball.setup(direction, damage, speed, lifetime)
			return fireball
		&"capoo_smg_bullet":
			var smg_bullet := (
				_acquire_or_instantiate_projectile(CAPOO_SMG_BULLET_SCENE)
				as CapooAK47Bullet
			)
			if smg_bullet == null:
				return null
			smg_bullet.top_level = true
			smg_bullet.setup(direction, damage, speed, lifetime)
			return smg_bullet
		&"yuanshi_fire_projectile":
			var fire_projectile := (
				_acquire_or_instantiate_projectile(YUANSHI_FIRE_PROJECTILE_SCENE)
				as YuanshiInsectFireProjectile
			)
			if fire_projectile == null:
				return null
			fire_projectile.top_level = true
			fire_projectile.setup(direction, damage, speed, lifetime)
			return fire_projectile
		&"linglan_skill1":
			_ensure_linglan_projectile_resources(projectile_type)
			if _linglan_sakura_bullet_scene == null:
				return null
			var sakura_bullet := (
				_acquire_or_instantiate_projectile(_linglan_sakura_bullet_scene)
				as LinglanSakuraBullet
			)
			if sakura_bullet == null:
				return null
			sakura_bullet.top_level = true
			sakura_bullet.setup(direction, damage, speed, lifetime)
			return sakura_bullet
		&"linglan_skill2_rocket":
			_ensure_linglan_projectile_resources(projectile_type)
			if _linglan_skill2_rocket_scene == null or _linglan_skill2_config == null:
				return null
			var sakura_rocket := _linglan_skill2_rocket_scene.instantiate() as Node2D
			if sakura_rocket == null:
				return null
			sakura_rocket.top_level = true
			var rocket_target: Player = null
			if game != null and target_peer_id > 0:
				rocket_target = game.get_player_for_peer(target_peer_id)
			sakura_rocket.call(
				"setup",
				direction,
				damage,
				speed,
				lifetime,
				float(_linglan_skill2_config.get("rocket_explosion_radius")),
				rocket_target,
				float(_linglan_skill2_config.get("rocket_homing_turn_rate"))
			)
			return sakura_rocket
		&"collectible_sakura_rocket":
			_ensure_linglan_projectile_resources(projectile_type)
			if _collectible_sakura_rocket_scene == null:
				return null
			var collectible_sakura_rocket := (
				_acquire_or_instantiate_projectile(_collectible_sakura_rocket_scene)
				as Node2D
			)
			if collectible_sakura_rocket == null:
				return null
			collectible_sakura_rocket.top_level = true
			var collectible_explosion_radius := float(
				collectible_sakura_rocket.get("explosion_radius")
			)
			var collectible_homing_turn_rate := float(
				collectible_sakura_rocket.get("homing_turn_rate")
			)
			var target_enemy: Enemy = null
			if game != null and target_enemy_net_id > 0:
				target_enemy = game.get_enemy_for_net_id(target_enemy_net_id)
			collectible_sakura_rocket.call(
				"setup",
				direction,
				damage,
				speed,
				lifetime,
				collectible_explosion_radius,
				null,
				collectible_homing_turn_rate,
				target_enemy,
				true,
				EnemyConfig.DamageType.MAGIC
			)
			return collectible_sakura_rocket
		&"linglan_skill3_orb":
			_ensure_linglan_projectile_resources(projectile_type)
			if _linglan_skill3_orb_scene == null or _linglan_skill3_config == null:
				return null
			var light_orb := _linglan_skill3_orb_scene.instantiate() as Node2D
			if light_orb == null:
				return null
			light_orb.top_level = true
			light_orb.call(
				"setup",
				direction,
				damage,
				speed,
				lifetime,
				float(_linglan_skill3_config.get("orb_base_radius")),
				float(_linglan_skill3_config.get("orb_grow_scale")),
				float(_linglan_skill3_config.get("orb_expanded_hold_duration")),
				float(_linglan_skill3_config.get("orb_flash_lead_time"))
			)
			return light_orb
		&"linglan_skill4_orb":
			_ensure_linglan_projectile_resources(projectile_type)
			if _linglan_skill4_orb_scene == null or _linglan_skill4_config == null:
				return null
			var skill4_orb := _linglan_skill4_orb_scene.instantiate() as Node2D
			if skill4_orb == null:
				return null
			skill4_orb.top_level = true
			skill4_orb.call(
				"setup",
				direction,
				damage,
				speed,
				lifetime,
				float(_linglan_skill4_config.get("orb_radius")),
				float(_linglan_skill4_config.get("orb_damage_radius"))
			)
			return skill4_orb
		_:
			return null


func _ensure_linglan_projectile_resources(projectile_type: StringName) -> void:
	match projectile_type:
		&"linglan_skill1":
			if _linglan_sakura_bullet_scene == null:
				_linglan_sakura_bullet_scene = load(
					LINGLAN_SAKURA_BULLET_SCENE_PATH
				) as PackedScene
		&"linglan_skill2_rocket":
			if _linglan_skill2_config == null:
				_linglan_skill2_config = load(LINGLAN_SKILL2_CONFIG_PATH)
			if _linglan_skill2_rocket_scene == null:
				_linglan_skill2_rocket_scene = load(
					LINGLAN_SKILL2_ROCKET_SCENE_PATH
				) as PackedScene
		&"collectible_sakura_rocket":
			if _collectible_sakura_rocket_scene == null:
				_collectible_sakura_rocket_scene = load(
					COLLECTIBLE_SAKURA_ROCKET_SCENE_PATH
				) as PackedScene
		&"linglan_skill3_orb":
			if _linglan_skill3_config == null:
				_linglan_skill3_config = load(LINGLAN_SKILL3_CONFIG_PATH)
			if _linglan_skill3_orb_scene == null:
				_linglan_skill3_orb_scene = load(
					LINGLAN_SKILL3_ORB_SCENE_PATH
				) as PackedScene
		&"linglan_skill4_orb":
			if _linglan_skill4_config == null:
				_linglan_skill4_config = load(LINGLAN_SKILL4_CONFIG_PATH)
			if _linglan_skill4_orb_scene == null:
				_linglan_skill4_orb_scene = load(
					LINGLAN_SKILL4_ORB_SCENE_PATH
				) as PackedScene
			if _linglan_skill4_orb_script == null:
				_linglan_skill4_orb_script = load(LINGLAN_SKILL4_ORB_SCRIPT_PATH) as Script


func _get_authoritative_client_projectile_parameters(
	projectile_type: StringName,
	owner_peer_id: int
) -> Dictionary:
	var owner_player: Player = null
	if game != null:
		owner_player = game.get_player_for_peer(owner_peer_id)
	if owner_player == null or not is_instance_valid(owner_player):
		return {}
	match projectile_type:
		&"player_bullet":
			if not owner_player.can_request_multiplayer_projectile(projectile_type):
				return {}
			if owner_player.has_method("try_accept_authoritative_primary_shot"):
				if not bool(owner_player.call(
					"try_accept_authoritative_primary_shot",
					projectile_type
				)):
					return {}
			elif not owner_player.try_consume_authoritative_player_bullet_ammo():
				return {}
			var bullet_scene := _get_runtime_packed_scene(BULLET_SCENE_PATH)
			if bullet_scene == null:
				return {}
			var bullet_defaults := _get_cached_projectile_defaults(
				projectile_type,
				bullet_scene
			)
			if bullet_defaults.is_empty():
				return {}
			return {
				"damage": owner_player.get_outgoing_damage(
					owner_player.attack_damage,
					EnemyConfig.DamageType.PHYSICAL
				),
				"speed": float(bullet_defaults["speed"]),
				"lifetime": float(bullet_defaults["lifetime"]),
				"pierces_enemies": (
					randf() < owner_player.get_inventory_bullet_pierce_chance()
				),
				"homes_to_enemy": (
					randf() < owner_player._get_inventory_bullet_homing_chance()
				),
			}
		TIYI_SNIPER_PROJECTILE_TYPE:
			if not _is_valid_tiyi_player(owner_player):
				return {}
			if not owner_player.can_request_multiplayer_projectile(projectile_type):
				return {}
			if not owner_player.has_method("try_accept_authoritative_primary_shot"):
				return {}
			if not bool(
				owner_player.call("try_accept_authoritative_primary_shot", projectile_type)
			):
				return {}
			var sniper_scene := _get_runtime_packed_scene(TIYI_SNIPER_BULLET_SCENE_PATH)
			if sniper_scene == null:
				return {}
			var sniper_defaults := _get_cached_projectile_defaults(
				projectile_type,
				sniper_scene
			)
			if sniper_defaults.is_empty():
				return {}
			return {
				"damage": owner_player.get_outgoing_damage(
					owner_player.attack_damage,
					EnemyConfig.DamageType.MAGIC
				),
				"speed": float(sniper_defaults["speed"]),
				"lifetime": float(sniper_defaults["lifetime"]),
				"pierces_enemies": (
					randf() < owner_player.get_inventory_bullet_pierce_chance()
				),
				"homes_to_enemy": (
					randf() < owner_player._get_inventory_bullet_homing_chance()
				),
			}
		&"skill1_bomb":
			if not owner_player.can_request_multiplayer_projectile(projectile_type):
				return {}
			if not owner_player.consume_multiplayer_skill1_charge():
				return {}
			owner_player.activate_collectible_skill_effects_from_multiplayer()
			var bomb_scene := _get_runtime_packed_scene(SKILL1_BOMB_SCENE_PATH)
			if bomb_scene == null:
				return {}
			var bomb := bomb_scene.instantiate() as Node2D
			if bomb == null:
				return {}
			var bomb_result := {
				"damage": owner_player.get_skill1_projectile_damage(),
				"speed": float(bomb.get("speed")),
				"lifetime": float(bomb.get("max_lifetime")),
			}
			bomb.free()
			return bomb_result
		&"collectible_arrow":
			var arrow_damage := _get_authoritative_collectible_arrow_damage(owner_player)
			if arrow_damage <= 0:
				return {}
			var arrow := COLLECTIBLE_ARROW_PROJECTILE_SCENE.instantiate()
			if arrow == null:
				return {}
			var arrow_result := {
				"damage": arrow_damage,
				"speed": float(arrow.get("speed")),
				"lifetime": float(arrow.get("max_lifetime")),
			}
			arrow.free()
			return arrow_result
		_:
			return {}


func _get_authoritative_collectible_arrow_damage(owner_player: Player) -> int:
	if owner_player == null or not is_instance_valid(owner_player):
		return -1
	var active_items_variant: Variant = owner_player.call("_get_active_collectible_items")
	if not (active_items_variant is Array):
		return -1

	var best_damage := -1
	for item_variant in active_items_variant:
		var item := item_variant as PickupConfig
		if item == null:
			continue
		if item.periodic_effect_id != PickupConfig.PERIODIC_EFFECT_ARCHER:
			continue
		var damage_multiplier := maxf(item.periodic_attack_damage_multiplier, 0.0)
		if damage_multiplier <= 0.0:
			damage_multiplier = 1.0
		var arrow_damage := owner_player.get_collectible_outgoing_damage(
			maxi(roundi(float(owner_player.attack_damage) * damage_multiplier), 1),
			EnemyConfig.DamageType.PHYSICAL
		)
		best_damage = maxi(best_damage, arrow_damage)
	return best_damage


func _remember_projectile_record(
	projectile_id: int,
	owner_peer_id: int,
	projectile_type: StringName,
	damage: int,
	lifetime: float,
	pierces_enemies: bool = false
) -> void:
	if projectile_id <= 0:
		return
	_projectile_records[projectile_id] = {
		"owner_peer_id": owner_peer_id,
		"projectile_type": projectile_type,
		"damage": maxi(damage, 0),
		"pierces_enemies": pierces_enemies,
		"confirmed_hit_consumed": false,
		"expires_at": _get_net_time() + maxf(lifetime, 0.0) + PROJECTILE_RECORD_RETENTION_SECONDS,
	}


func _get_authoritative_projectile_damage(
	projectile_id: int,
	owner_peer_id: int,
	reported_damage: int,
	projectile_type: StringName = &"player_bullet"
) -> int:
	if not _is_projectile_id_valid_for_owner(projectile_id, owner_peer_id):
		return -1
	var record_variant: Variant = _projectile_records.get(projectile_id)
	if record_variant != null:
		var record := record_variant as Dictionary
		if record.is_empty():
			return -1
		if int(record.get("owner_peer_id", 0)) != owner_peer_id:
			return -1
		return int(record.get("damage", -1))
	return _get_bounded_player_projectile_damage(
		owner_peer_id,
		reported_damage,
		projectile_type
	)


func _get_bounded_player_projectile_damage(
	owner_peer_id: int,
	reported_damage: int,
	projectile_type: StringName = &"player_bullet"
) -> int:
	if reported_damage <= 0:
		return -1
	var owner_player: Player = null
	if game != null:
		owner_player = game.get_player_for_peer(owner_peer_id)
	if owner_player == null or not is_instance_valid(owner_player):
		return -1
	var max_authoritative_damage := owner_player.get_outgoing_damage(
		owner_player.attack_damage,
		_get_player_projectile_damage_type(projectile_type)
	)
	if owner_player.has_skill1():
		max_authoritative_damage = maxi(
			max_authoritative_damage,
			owner_player.get_skill1_projectile_damage()
		)
	return clampi(reported_damage, 1, max_authoritative_damage)


func _get_player_projectile_damage_type(
	projectile_type: StringName
) -> EnemyConfig.DamageType:
	if projectile_type == TIYI_SNIPER_PROJECTILE_TYPE:
		return EnemyConfig.DamageType.MAGIC
	return EnemyConfig.DamageType.PHYSICAL


func _is_projectile_id_valid_for_owner(projectile_id: int, owner_peer_id: int) -> bool:
	return (
		owner_peer_id > 0
		and owner_peer_id <= PROJECTILE_ID_MAX_OWNER_PEER_ID
		and _decode_projectile_owner_peer_id(projectile_id) == owner_peer_id
		and _decode_projectile_sequence(projectile_id) > 0
	)


func _is_projectile_id_valid_for_client_owner(
	projectile_id: int,
	owner_peer_id: int
) -> bool:
	return (
		_is_projectile_id_valid_for_owner(projectile_id, owner_peer_id)
		and not _is_host_origin_projectile_id(projectile_id)
	)


func _is_projectile_id_valid_for_host_owner(
	projectile_id: int,
	owner_peer_id: int
) -> bool:
	return (
		_is_projectile_id_valid_for_owner(projectile_id, owner_peer_id)
		and _is_host_origin_projectile_id(projectile_id)
	)


func _encode_projectile_id(owner_peer_id: int, sequence: int) -> int:
	if (
		owner_peer_id <= 0
		or owner_peer_id > PROJECTILE_ID_MAX_OWNER_PEER_ID
		or sequence <= 0
		or sequence > PROJECTILE_ID_SEQUENCE_MASK
	):
		return 0
	return (owner_peer_id << PROJECTILE_ID_SEQUENCE_BITS) | sequence


func _decode_projectile_owner_peer_id(projectile_id: int) -> int:
	if projectile_id <= 0:
		return 0
	return projectile_id >> PROJECTILE_ID_SEQUENCE_BITS


func _decode_projectile_sequence(projectile_id: int) -> int:
	if projectile_id <= 0:
		return 0
	return projectile_id & PROJECTILE_ID_SEQUENCE_MASK


func _decode_projectile_sequence_counter(projectile_id: int) -> int:
	return _decode_projectile_sequence(projectile_id) & PROJECTILE_ID_SEQUENCE_COUNTER_MASK


func _is_host_origin_projectile_id(projectile_id: int) -> bool:
	return (
		_decode_projectile_sequence(projectile_id)
		& PROJECTILE_ID_HOST_ORIGIN_BIT
	) != 0


func _get_valid_client_projectile_direction(direction: Vector2) -> Vector2:
	if not _is_finite_vector2(direction):
		return Vector2.ZERO
	var direction_length := direction.length()
	if (
		direction_length < CLIENT_PROJECTILE_DIRECTION_MIN_LENGTH
		or direction_length > CLIENT_PROJECTILE_DIRECTION_MAX_LENGTH
	):
		return Vector2.ZERO
	return direction / direction_length


func _validate_client_homing_target(
	projectile_type: StringName,
	spawn_position: Vector2,
	direction: Vector2,
	target_enemy_net_id: int,
	can_home: bool
) -> int:
	if (
		projectile_type != &"player_bullet"
		and projectile_type != TIYI_SNIPER_PROJECTILE_TYPE
	) or not can_home or target_enemy_net_id <= 0:
		return 0
	var enemy := _get_host_enemy_for_net_id(target_enemy_net_id)
	if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
		return 0
	var target_offset := enemy.global_position - spawn_position
	if (
		target_offset.length_squared() <= 0.001
		or target_offset.length() > Player.HOMING_TARGET_RADIUS + 16.0
	):
		return 0
	if abs(direction.angle_to(target_offset.normalized())) > Player.HOMING_TARGET_HALF_ANGLE:
		return 0
	return target_enemy_net_id


func _is_client_projectile_spawn_position_allowed(
	projectile_type: StringName,
	owner_peer_id: int,
	spawn_position: Vector2
) -> bool:
	if not _is_finite_vector2(spawn_position):
		return false
	var owner_player: Player = null
	if game != null:
		owner_player = game.get_player_for_peer(owner_peer_id)
	if owner_player == null or not is_instance_valid(owner_player):
		return false
	var projectile_spawn_distance := (
		owner_player.get_multiplayer_projectile_spawn_distance(projectile_type)
	)
	if projectile_spawn_distance <= 0.0:
		return false
	var allowed_distance := (
		CLIENT_PROJECTILE_SPAWN_POSITION_TOLERANCE + projectile_spawn_distance
	)
	if owner_player.global_position.distance_to(spawn_position) <= allowed_distance:
		return true
	if _accepted_player_state_positions.has(owner_peer_id):
		var accepted_position := _accepted_player_state_positions[owner_peer_id] as Vector2
		if accepted_position.distance_to(spawn_position) <= allowed_distance:
			return true
	return false


func _get_authoritative_client_projectile_spawn_position(
	projectile_type: StringName,
	owner_peer_id: int,
	reported_spawn_position: Vector2,
	accepted_direction: Vector2
) -> Vector2:
	if projectile_type != TIYI_SNIPER_PROJECTILE_TYPE:
		return reported_spawn_position
	var owner_player := game.get_player_for_peer(owner_peer_id) if game != null else null
	if not _is_valid_tiyi_player(owner_player) or accepted_direction == Vector2.ZERO:
		return Vector2(INF, INF)
	var muzzle_distance := owner_player.get_multiplayer_projectile_spawn_distance(projectile_type)
	if muzzle_distance <= 0.0:
		return Vector2(INF, INF)
	return owner_player.global_position + accepted_direction * muzzle_distance


func _is_finite_vector2(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y)


func _is_valid_linglan_skill1_ring_payload(
	projectile_ids: PackedInt64Array,
	spawn_positions: PackedVector2Array,
	directions: PackedVector2Array,
	owner_peer_id: int,
	damage: int,
	speed: float,
	lifetime: float,
	host_fire_timestamp: float
) -> bool:
	var projectile_count := projectile_ids.size()
	if (
		projectile_count <= 0
		or projectile_count > LINGLAN_SKILL1_RING_MAX_PROJECTILES_PER_PACKET
		or spawn_positions.size() != projectile_count
		or directions.size() != projectile_count
		or owner_peer_id <= 0
		or damage < 0
		or not is_finite(speed)
		or speed < 0.0
		or not is_finite(lifetime)
		or lifetime <= 0.0
		or not is_finite(host_fire_timestamp)
		or host_fire_timestamp < 0.0
	):
		return false
	var seen_projectile_ids: Dictionary[int, bool] = {}
	for projectile_index in range(projectile_count):
		var projectile_id := int(projectile_ids[projectile_index])
		var direction := directions[projectile_index]
		if (
			seen_projectile_ids.has(projectile_id)
			or not _is_projectile_id_valid_for_host_owner(
				projectile_id,
				owner_peer_id
			)
			or not _is_finite_vector2(spawn_positions[projectile_index])
			or not _is_finite_vector2(direction)
			or direction.length_squared() <= 0.001
		):
			return false
		seen_projectile_ids[projectile_id] = true
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
	_stale_projectile_record_ids.clear()
	for projectile_id_variant in _projectile_records:
		var projectile_id := int(projectile_id_variant)
		var record := _projectile_records[projectile_id] as Dictionary
		if record.is_empty() or float(record.get("expires_at", 0.0)) <= now:
			_stale_projectile_record_ids.append(projectile_id)
	for projectile_id in _stale_projectile_record_ids:
		_projectile_records.erase(projectile_id)


func _setup_projectile_network_identity(
	projectile: Node,
	projectile_id: int,
	owner_peer_id: int,
	projectile_type: StringName
) -> void:
	if projectile.has_method("setup_multiplayer"):
		projectile.call("setup_multiplayer", projectile_id, owner_peer_id, projectile_type)
	if projectile.has_signal(&"projectile_finished"):
		var finished_callable := Callable(self, "_on_network_projectile_finished")
		if not projectile.is_connected(&"projectile_finished", finished_callable):
			projectile.connect(&"projectile_finished", finished_callable)
	if not projectile.has_meta(SessionObjectPool.POOL_OWNER_META):
		projectile.tree_exited.connect(
			_on_network_projectile_tree_exited.bind(projectile_id, projectile),
			CONNECT_ONE_SHOT
		)


func _on_network_projectile_finished(projectile_id: int, projectile: Node) -> void:
	if _known_projectiles.get(projectile_id) == projectile:
		_known_projectiles.erase(projectile_id)


func _on_network_projectile_tree_exited(projectile_id: int, projectile: Node) -> void:
	if _known_projectiles.get(projectile_id) == projectile:
		_known_projectiles.erase(projectile_id)


func _update_recent_event_cache_prune(delta: float) -> void:
	_recent_event_prune_time_left = maxf(_recent_event_prune_time_left - delta, 0.0)
	if _recent_event_prune_time_left > 0.0:
		return
	_recent_event_prune_time_left = RECENT_EVENT_PRUNE_INTERVAL_SECONDS
	_prune_recent_event_caches(_get_net_time())


func _prune_recent_event_caches(now: float) -> void:
	_prune_recent_event_cache(_processed_enemy_hit_ids, now)
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
	if net_manager.is_host():
		_apply_enemy_hit_report(projectile_id, owner_peer_id, enemy_net_id, damage, impact_direction)
	else:
		_rpc_enemy_hit_report.rpc_id(
			_get_host_peer_id(),
			projectile_id,
			owner_peer_id,
			enemy_net_id,
			damage,
			impact_direction
		)


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
		return enemy.apply_damage(
			damage,
			impact_direction,
			damage_type as EnemyConfig.DamageType,
			show_hit_particles
		)
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
	projectile_id: int,
	owner_peer_id: int,
	enemy_net_id: int,
	damage: int,
	impact_direction: Vector2
) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if not _is_client_enemy_hit_report_allowed(projectile_id, owner_peer_id, sender_id):
		return
	_apply_enemy_hit_report(projectile_id, owner_peer_id, enemy_net_id, damage, impact_direction)


func _is_client_enemy_hit_report_allowed(
	projectile_id: int,
	owner_peer_id: int,
	sender_id: int
) -> bool:
	if sender_id > 0:
		if owner_peer_id != sender_id:
			return false
		# Host-origin identities are simulated and settled by Host. A remote
		# client may only report collisions for its own prediction lane; otherwise
		# it could submit a hit for an unrelated Host-authoritative projectile
		# whose owner field happens to match that peer.
		if not _is_projectile_id_valid_for_client_owner(
			projectile_id,
			owner_peer_id
		):
			return false
	var projectile_record_variant: Variant = _projectile_records.get(projectile_id)
	if projectile_record_variant is Dictionary:
		var projectile_record := projectile_record_variant as Dictionary
		var projectile_type := StringName(projectile_record.get("projectile_type", &""))
		if projectile_type == TIYI_SNIPER_PROJECTILE_TYPE or projectile_type == &"skill1_bomb":
			# These projectiles are simulated and settled by Host. Clients cannot claim hits.
			return false
	return true


func _apply_enemy_hit_report(
	projectile_id: int,
	owner_peer_id: int,
	enemy_net_id: int,
	reported_damage: int,
	impact_direction: Vector2
) -> void:
	if projectile_id <= 0 or owner_peer_id <= 0 or enemy_net_id <= 0:
		return
	if not _is_projectile_id_valid_for_owner(projectile_id, owner_peer_id):
		return
	var projectile_record_variant: Variant = _projectile_records.get(projectile_id)
	if not (projectile_record_variant is Dictionary):
		return
	var projectile_record := projectile_record_variant as Dictionary
	if projectile_record.is_empty():
		return
	var projectile_type := StringName(projectile_record.get("projectile_type", &""))
	var consumes_first_confirmed_hit := (
		(projectile_type == &"player_bullet" or projectile_type == TIYI_SNIPER_PROJECTILE_TYPE)
		and not bool(projectile_record.get("pierces_enemies", false))
	)
	if consumes_first_confirmed_hit and bool(projectile_record.get("confirmed_hit_consumed", false)):
		return
	var authoritative_damage := _get_authoritative_projectile_damage(
		projectile_id,
		owner_peer_id,
		reported_damage,
		projectile_type
	)
	if authoritative_damage <= 0:
		return
	var hit_key := "%d:%d" % [projectile_id, enemy_net_id]
	var now := _get_net_time()
	if _is_recent_event_cached(_processed_enemy_hit_ids, hit_key, now):
		return
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
	if consumes_first_confirmed_hit:
		projectile_record["confirmed_hit_consumed"] = true
		_projectile_records[projectile_id] = projectile_record
	_remember_recent_event(_processed_enemy_hit_ids, hit_key, HIT_DEDUP_RETENTION_SECONDS, now)
	if projectile_type == TIYI_SNIPER_PROJECTILE_TYPE:
		var authoritative_hit_position := enemy.global_position
		var authoritative_direction := _get_valid_client_projectile_direction(-impact_direction)
		var projectile_variant: Variant = _known_projectiles.get(projectile_id)
		if projectile_variant != null and is_instance_valid(projectile_variant):
			var projectile_node := projectile_variant as Node2D
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
	var safe_direction := _get_valid_client_projectile_direction(direction)
	if safe_direction == Vector2.ZERO:
		safe_direction = Vector2.RIGHT
	var projectile_variant: Variant = _known_projectiles.get(projectile_id)
	if projectile_variant != null and is_instance_valid(projectile_variant):
		var projectile_node := projectile_variant as Node2D
		if projectile_node != null and projectile_node.has_method(
			"apply_authoritative_hit_confirmation"
		):
			projectile_node.call(
				"apply_authoritative_hit_confirmation",
				enemy_net_id,
				hit_position,
				safe_direction,
				continues_piercing
			)
			return
	var hit_effect_scene := _get_runtime_packed_scene(TIYI_SNIPER_HIT_EFFECT_SCENE_PATH)
	if hit_effect_scene == null:
		return
	var hit_effect := hit_effect_scene.instantiate() as Node2D
	if hit_effect == null:
		return
	hit_effect.top_level = true
	if hit_effect.has_method("setup"):
		hit_effect.call("setup", safe_direction)
	add_child(hit_effect)
	hit_effect.global_position = hit_position


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
	if not enemy.apply_damage(damage, impact_direction, damage_type, show_hit_particles):
		return false
	var confirmed_damage := enemy.last_damage_taken
	_queue_enemy_damage_feedback(
		enemy_net_id,
		enemy.current_health,
		confirmed_damage,
		impact_direction,
		damage_type,
		show_hit_particles
	)
	return true


func _queue_enemy_damage_feedback(
	enemy_net_id: int,
	current_health: int,
	confirmed_damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	show_hit_particles: bool
) -> void:
	if not is_inside_tree() or not net_manager.is_host() or enemy_net_id <= 0:
		return
	var feedback := _pending_enemy_damage_feedback.get(enemy_net_id, {}) as Dictionary
	if feedback.is_empty():
		feedback = {
			"current_health": current_health,
			"damage": 0,
			"impact_direction": impact_direction,
			"damage_type": int(damage_type),
			"show_hit_particles": show_hit_particles,
		}
	feedback["current_health"] = current_health
	feedback["damage"] = int(feedback.get("damage", 0)) + maxi(confirmed_damage, 0)
	feedback["impact_direction"] = impact_direction
	feedback["damage_type"] = int(damage_type)
	feedback["show_hit_particles"] = (
		bool(feedback.get("show_hit_particles", false)) or show_hit_particles
	)
	_pending_enemy_damage_feedback[enemy_net_id] = feedback


func _update_batched_network_events(delta: float) -> void:
	if not net_manager.is_host():
		return
	_combat_feedback_flush_time_left -= maxf(delta, 0.0)
	if _combat_feedback_flush_time_left <= 0.0:
		_combat_feedback_flush_time_left = COMBAT_FEEDBACK_FLUSH_INTERVAL_SECONDS
		_flush_enemy_damage_feedback()
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
	_wave_progress_flush_time_left -= maxf(delta, 0.0)
	if _wave_progress_flush_time_left <= 0.0:
		_wave_progress_flush_time_left = WAVE_PROGRESS_FLUSH_INTERVAL_SECONDS
		_flush_wave_progress()
		_flush_tiyi_target_updates()


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
	if _pending_enemy_damage_feedback.is_empty():
		return
	var enemy_ids: Array[int] = []
	for enemy_id_variant in _pending_enemy_damage_feedback.keys():
		enemy_ids.append(int(enemy_id_variant))
	enemy_ids.sort()
	for chunk_start in range(0, enemy_ids.size(), COMBAT_FEEDBACK_MAX_RECORDS_PER_PACKET):
		var chunk_end := mini(
			chunk_start + COMBAT_FEEDBACK_MAX_RECORDS_PER_PACKET,
			enemy_ids.size()
		)
		var net_ids := PackedInt32Array()
		var health_values := PackedInt32Array()
		var damage_values := PackedInt32Array()
		var directions := PackedVector2Array()
		var damage_types := PackedByteArray()
		var particle_flags := PackedByteArray()
		for record_index in range(chunk_start, chunk_end):
			var enemy_id := enemy_ids[record_index]
			var feedback := _pending_enemy_damage_feedback.get(enemy_id, {}) as Dictionary
			net_ids.append(enemy_id)
			health_values.append(int(feedback.get("current_health", 0)))
			damage_values.append(int(feedback.get("damage", 0)))
			directions.append(feedback.get("impact_direction", Vector2.ZERO) as Vector2)
			damage_types.append(int(feedback.get("damage_type", 0)))
			particle_flags.append(1 if bool(feedback.get("show_hit_particles", false)) else 0)
		_rpc_to_connected_clients(
			&"net_enemy_damage_feedback_batch",
			[net_ids, health_values, damage_values, directions, damage_types, particle_flags]
		)
	_pending_enemy_damage_feedback.clear()


func _flush_plant_health_updates() -> void:
	if _pending_plant_health_updates.is_empty():
		return
	var net_ids := PackedInt32Array()
	for net_id_variant in _pending_plant_health_updates.keys():
		net_ids.append(int(net_id_variant))
	net_ids.sort()
	_send_pending_plant_health_updates(net_ids)
	for net_id in net_ids:
		_pending_plant_health_updates.erase(net_id)


func _send_pending_plant_health_updates(net_ids: PackedInt32Array) -> void:
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
			chunk_ids.append(net_id)
			health_values.append(int(update.get("current_health", 0)))
			maximum_values.append(int(update.get("maximum_health", 1)))
			revisions.append(int(update.get("health_revision", 0)))
			damage_values.append(int(update.get("damage", 0)))
			healing_values.append(int(update.get("healing", 0)))
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
	if game == null or net_manager.is_host():
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
		var live_plant_before := game.get_multiplayer_plant_node(net_id)
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
		game == null
		or net_manager.is_host()
		or net_id <= 0
		or health_revision < 0
		or _removed_remote_plant_ids.has(net_id)
	):
		return
	var plant := game.get_multiplayer_plant_node(net_id)
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
	game.apply_remote_plant_health(
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
	var pending := _pending_remote_plant_health_updates.get(net_id, {}) as Dictionary
	if pending.is_empty():
		return
	var plant := game.get_multiplayer_plant_node(net_id)
	if plant == null or not is_instance_valid(plant):
		return
	_erase_pending_remote_plant_health(net_id)
	game.apply_remote_plant_health(
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
	damage_values: PackedInt32Array,
	directions: PackedVector2Array,
	damage_types: PackedByteArray,
	particle_flags: PackedByteArray
) -> void:
	var record_count := mini(
		net_ids.size(),
		mini(
			health_values.size(),
			mini(
				damage_values.size(),
				mini(directions.size(), mini(damage_types.size(), particle_flags.size()))
			)
		)
	)
	for record_index in range(record_count):
		var enemy := _get_client_enemy_for_net_id(net_ids[record_index])
		if enemy == null or not is_instance_valid(enemy):
			continue
		_apply_enemy_network_health(enemy, health_values[record_index])
		enemy.show_damage_number(
			damage_values[record_index],
			directions[record_index],
			int(damage_types[record_index]) as EnemyConfig.DamageType
		)
		if directions[record_index] != Vector2.ZERO:
			enemy.play_multiplayer_damage_feedback(
				directions[record_index],
				particle_flags[record_index] != 0
			)


@rpc("authority", "call_remote", "unreliable", 7)
func net_enemy_damage_applied(
	enemy_net_id: int,
	current_health: int,
	is_dead: bool,
	confirmed_damage: int,
	impact_direction: Vector2,
	damage_type: int = EnemyConfig.DamageType.PHYSICAL,
	show_hit_particles: bool = true
) -> void:
	var enemy := _get_client_enemy_for_net_id(enemy_net_id)
	if enemy == null or not is_instance_valid(enemy):
		return
	_apply_enemy_network_health(enemy, current_health)
	enemy.show_damage_number(
		confirmed_damage,
		impact_direction,
		damage_type as EnemyConfig.DamageType
	)
	if impact_direction != Vector2.ZERO:
		enemy.play_multiplayer_damage_feedback(impact_direction, show_hit_particles)
	if is_dead:
		_remove_client_enemy(enemy_net_id, true)


func _next_player_hit_revision() -> int:
	_local_player_hit_revision += 1
	return _local_player_hit_revision


func request_multiplayer_player_damage(
	source_id: int,
	target_peer_id: int,
	damage: int,
	source_type: StringName,
	damage_type_or_source_direction: Variant = EnemyConfig.DamageType.PHYSICAL,
	source_direction_or_is_ranged: Variant = Vector2.ZERO,
	is_ranged: bool = false
) -> bool:
	if source_id <= 0 or target_peer_id <= 0 or damage <= 0:
		return false
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
	var damage_context := _build_player_damage_context(source_direction, resolved_is_ranged)
	var impact_direction := Vector2.ZERO
	if source_direction.is_finite() and source_direction.length_squared() > 0.001:
		impact_direction = -source_direction.normalized()
	var hit_key := "%d:%d:%s" % [source_id, target_peer_id, String(source_type)]
	var now := _get_net_time()
	var player_node: Player = null
	if game != null:
		player_node = game.get_player_for_peer(target_peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return false
	if _is_recent_event_cached(_processed_player_hit_ids, hit_key, now):
		return true
	if net_manager.is_client():
		if target_peer_id != _get_local_peer_id():
			return true
		if player_node.is_dead:
			return true
		if player_node.apply_damage(damage, resolved_damage_type, damage_context):
			_remember_recent_event(_processed_player_hit_ids, hit_key, HIT_DEDUP_RETENTION_SECONDS, now)
			request_player_hit_report(
				source_id,
				target_peer_id,
				damage,
				source_type,
				player_node.current_health,
				player_node.is_dead,
				player_node.last_damage_taken,
				impact_direction,
				resolved_damage_type
			)
		return true
	if net_manager.is_host():
		if player_node.is_dead:
			return true
		if player_node.apply_damage(damage, resolved_damage_type, damage_context):
			_apply_player_hit_report(
				source_id,
				target_peer_id,
				damage,
				source_type,
				player_node.current_health,
				player_node.is_dead,
				_next_player_hit_revision(),
				player_node.last_damage_taken,
				impact_direction,
				resolved_damage_type
			)
		return true
	return false


func _build_player_damage_context(source_direction: Vector2, is_ranged: bool) -> Dictionary:
	if not is_ranged:
		return {}
	return {
		"is_ranged": true,
		"source_direction": (
			source_direction.normalized()
			if source_direction.is_finite() and source_direction.length_squared() > 0.001
			else Vector2.ZERO
		),
	}


func request_player_hit_report(
	source_id: int,
	player_peer_id: int,
	damage: int,
	source_type: StringName,
	reported_health_after: int,
	reported_is_dead: bool,
	reported_applied_damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> void:
	var hit_revision := _next_player_hit_revision()
	if net_manager.is_host():
		_apply_player_hit_report(
			source_id,
			player_peer_id,
			damage,
			source_type,
			reported_health_after,
			reported_is_dead,
			hit_revision,
			reported_applied_damage,
			impact_direction,
			damage_type
		)
	else:
		_rpc_player_hit_report.rpc_id(
			_get_host_peer_id(),
			source_id,
			player_peer_id,
			damage,
			String(source_type),
			reported_health_after,
			reported_is_dead,
			hit_revision,
			reported_applied_damage,
			impact_direction,
			int(damage_type)
		)


@rpc("any_peer", "call_remote", "reliable", 5)
func _rpc_player_hit_report(
	source_id: int,
	player_peer_id: int,
	damage: int,
	source_type: String,
	reported_health_after: int,
	reported_is_dead: bool,
	hit_revision: int,
	reported_applied_damage: int,
	impact_direction: Vector2,
	damage_type: int
) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id > 0 and sender_id != player_peer_id:
		return
	_apply_player_hit_report(
		source_id,
		player_peer_id,
		damage,
		StringName(source_type),
		reported_health_after,
		reported_is_dead,
		hit_revision,
		reported_applied_damage,
		impact_direction,
		damage_type as EnemyConfig.DamageType
	)


func _apply_player_hit_report(
	source_id: int,
	player_peer_id: int,
	damage: int,
	source_type: StringName,
	reported_health_after: int,
	reported_is_dead: bool,
	_hit_revision: int,
	reported_applied_damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> void:
	if source_id <= 0 or player_peer_id <= 0 or damage <= 0:
		return
	var hit_key := "%d:%d:%s" % [source_id, player_peer_id, String(source_type)]
	var now := _get_net_time()
	if _is_recent_event_cached(_processed_player_hit_ids, hit_key, now):
		return
	var player_node: Player = null
	if game != null:
		player_node = game.get_player_for_peer(player_peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if player_node.is_dead and not reported_is_dead:
		return
	_remember_recent_event(_processed_player_hit_ids, hit_key, HIT_DEDUP_RETENTION_SECONDS, now)
	var confirmed_health := clampi(reported_health_after, 0, player_node.max_health)
	if player_node.current_health > 0:
		confirmed_health = mini(confirmed_health, player_node.current_health)
	var confirmed_dead := reported_is_dead or confirmed_health <= 0
	var confirmed_damage := clampi(reported_applied_damage, 0, player_node.max_health)
	var confirmed_impact_direction := Vector2.ZERO
	if impact_direction.is_finite() and impact_direction.length_squared() > 0.001:
		confirmed_impact_direction = impact_direction.normalized()
	var confirmed_damage_type := (
		EnemyConfig.DamageType.MAGIC
		if damage_type == EnemyConfig.DamageType.MAGIC
		else EnemyConfig.DamageType.PHYSICAL
	)
	player_node.set_multiplayer_health_state(confirmed_health, confirmed_dead)
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
	_rpc_to_connected_clients(
		&"net_player_damage_applied",
		[
			player_peer_id,
			player_node.current_health,
			player_node.is_dead,
			health_revision,
			confirmed_damage,
			confirmed_impact_direction,
			int(confirmed_damage_type),
		]
	)
	net_player_damage_applied(
		player_peer_id,
		player_node.current_health,
		player_node.is_dead,
		health_revision,
		confirmed_damage,
		confirmed_impact_direction,
		int(confirmed_damage_type)
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_player_damage_applied(
	player_peer_id: int,
	current_health: int,
	is_dead: bool,
	health_revision: int,
	confirmed_damage: int,
	impact_direction: Vector2,
	damage_type: int
) -> void:
	if player_peer_id <= 0:
		return
	var player_node: Player = null
	if game != null:
		player_node = game.get_player_for_peer(player_peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if health_revision <= int(_player_health_revisions.get(player_peer_id, 0)):
		return
	_player_health_revisions[player_peer_id] = health_revision
	player_node.set_multiplayer_health_state(current_health, is_dead)
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
	if is_dead and _is_valid_tiyi_player(player_node):
		_active_tiyi_activations_by_peer.erase(player_peer_id)
		_tiyi_target_ids_by_peer.erase(player_peer_id)
		_clear_projectiles_for_peer(player_peer_id)
		_clear_projectile_records_for_peer(player_peer_id)
	if (
		is_client_view_runtime()
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
	if peer_id <= 0:
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
	player_node.set_multiplayer_health_state(current_health, false)
	player_node.queue_healing_number(confirmed_healing)


# Legacy compatibility shells retained in protocol v9. Xirang orbs no longer exist, but keeping the
# annotated signatures avoids a partial wire-protocol break until the next
# coordinated protocol-version upgrade.
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
	if net_manager.is_host():
		return _get_host_enemy_for_net_id(enemy_net_id)
	return _get_valid_client_enemy_for_net_id(enemy_net_id)


func get_all_combat_targets() -> Array[Enemy]:
	if game == null:
		return []
	if net_manager.is_host():
		return game.get_all_combat_targets()
	var result: Array[Enemy] = []
	for enemy_net_id_variant in _net_enemies:
		var enemy_variant: Variant = _net_enemies.get(int(enemy_net_id_variant))
		if enemy_variant == null or not is_instance_valid(enemy_variant):
			continue
		var enemy := enemy_variant as Enemy
		if enemy != null and not enemy.is_dead:
			result.append(enemy)
	return result


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
	var safe_radius := maxf(radius, 0.0)
	var radius_squared := safe_radius * safe_radius
	for enemy_net_id_variant in _net_enemies:
		var enemy_variant: Variant = _net_enemies.get(enemy_net_id_variant)
		if enemy_variant == null or not is_instance_valid(enemy_variant):
			continue
		var enemy := enemy_variant as Enemy
		if enemy == null or enemy.is_dead:
			continue
		if safe_radius > 0.0 and center.distance_squared_to(enemy.global_position) > radius_squared:
			continue
		result.append(enemy)
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
	var safe_radius := maxf(radius, 0.0)
	var radius_squared := safe_radius * safe_radius
	for enemy_net_id_variant in _net_enemies:
		var enemy_variant: Variant = _net_enemies.get(enemy_net_id_variant)
		if enemy_variant == null or not is_instance_valid(enemy_variant):
			continue
		var enemy := enemy_variant as Enemy
		if enemy == null or enemy.is_dead:
			continue
		if (
			safe_radius > 0.0
			and center.distance_squared_to(enemy.global_position) > radius_squared
		):
			continue
		result.append(enemy)


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
	if game == null:
		return null
	return game.get_enemy_for_net_id(enemy_net_id)


func _get_client_enemy_for_net_id(enemy_net_id: int) -> Enemy:
	return _get_valid_client_enemy_for_net_id(enemy_net_id)


func _get_valid_client_enemy_for_net_id(enemy_net_id: int) -> Enemy:
	var enemy_variant: Variant = _net_enemies.get(enemy_net_id)
	if enemy_variant == null:
		return null
	if not is_instance_valid(enemy_variant):
		_net_enemies.erase(enemy_net_id)
		_enemy_spawn_snapshot_times.erase(enemy_net_id)
		enemy_interpolators.erase(enemy_net_id)
		_offscreen_enemy_interpolation_slots.erase(enemy_net_id)
		return null
	return enemy_variant as Enemy

func _next_player_health_revision(peer_id: int) -> int:
	var next_revision := int(_player_health_revisions.get(peer_id, 0)) + 1
	_player_health_revisions[peer_id] = next_revision
	return next_revision


func _schedule_player_revive(peer_id: int) -> void:
	if peer_id <= 0 or _dead_player_revive_times.has(peer_id):
		return
	if game == null or game.wave_state in [
		GameRuntimeBase.WaveState.VICTORY,
		GameRuntimeBase.WaveState.DEFEAT,
	]:
		return
	_host_latest_client_player_snapshot_states.erase(peer_id)
	var revive_delay := game.consume_next_player_respawn_delay(peer_id)
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
	if game.wave_state in [
		GameRuntimeBase.WaveState.VICTORY,
		GameRuntimeBase.WaveState.DEFEAT,
	]:
		return
	var now := _get_net_time()
	var due_peers: Array[int] = []
	for peer_id_variant in _dead_player_revive_times:
		var peer_id := int(peer_id_variant)
		var revive_at := float(_dead_player_revive_times[peer_id])
		var seconds_left := maxi(ceili(revive_at - now), 0)
		if seconds_left != int(_dead_player_revive_last_seconds.get(peer_id, -1)):
			_dead_player_revive_last_seconds[peer_id] = seconds_left
			_rpc_to_connected_clients(&"net_player_revive_countdown", [peer_id, seconds_left])
			net_player_revive_countdown(peer_id, seconds_left)
		if now >= revive_at:
			due_peers.append(peer_id)
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
	if game == null or peer_id <= 0:
		return null
	var fixed_position: Variant = game.get_fixed_multiplayer_respawn_position(peer_id)
	if fixed_position is Vector2:
		return fixed_position
	if living_player_positions.is_empty():
		return null
	return _pick_multiplayer_revive_position(living_player_positions)


func _revive_player_peer(peer_id: int, revive_position: Vector2) -> void:
	var player_node: Player = null
	if game != null:
		player_node = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	var active_tiyi_activation_id := int(_active_tiyi_activations_by_peer.get(peer_id, 0))
	if active_tiyi_activation_id > 0:
		_cancel_authoritative_tiyi_high_noon(peer_id, active_tiyi_activation_id, true)
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
	if peer_id != _get_host_peer_id():
		_remember_latest_client_player_snapshot_state(
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
	var player_node := game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if game.supports_tower_defense():
		game.update_player_respawn_countdown(peer_id, seconds_left)
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
	if peer_id <= 0:
		return
	var player_node: Player = null
	if game != null:
		player_node = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if health_revision <= int(_player_health_revisions.get(peer_id, 0)):
		return
	_player_health_revisions[peer_id] = health_revision
	_dead_player_revive_times.erase(peer_id)
	_dead_player_revive_last_seconds.erase(peer_id)
	_active_tiyi_activations_by_peer.erase(peer_id)
	_tiyi_target_ids_by_peer.erase(peer_id)
	player_node.revive_multiplayer(revive_position, current_health, invincible_seconds)
	game.clear_player_respawn_countdown(peer_id)
	if is_client_view_runtime() and peer_id != _get_client_view_local_peer_id():
		_reset_player_visual_interpolator_to_state(
			peer_id,
			revive_position,
			Vector2.ZERO,
			player_node.get_multiplayer_facing_id(),
			player_node.get_multiplayer_anim_state()
		)

func _on_host_enemy_spawned(
	net_id: int,
	enemy_config: EnemyConfig,
	spawn_position: Vector2
) -> void:
	if enemy_config == null or not is_inside_tree() or not net_manager.is_host():
		return
	_pending_enemy_spawns.append({
		"net_id": net_id,
		"config_path": enemy_config.resource_path,
		"position": spawn_position,
		"spawn_time": _get_net_time(),
	})


func _flush_pending_enemy_spawns() -> void:
	if _pending_enemy_spawns.is_empty() or not net_manager.is_host():
		return
	var spawn_records := _pending_enemy_spawns.duplicate(true)
	_pending_enemy_spawns.clear()
	for chunk_start in range(0, spawn_records.size(), ENEMY_SPAWN_BATCH_MAX_RECORDS):
		var chunk_end := mini(
			chunk_start + ENEMY_SPAWN_BATCH_MAX_RECORDS,
			spawn_records.size()
		)
		var net_ids := PackedInt32Array()
		var config_paths := PackedStringArray()
		var positions := PackedVector2Array()
		var spawn_times := PackedFloat64Array()
		for record_index in range(chunk_start, chunk_end):
			var record := spawn_records[record_index] as Dictionary
			net_ids.append(int(record.get("net_id", 0)))
			config_paths.append(String(record.get("config_path", "")))
			positions.append(record.get("position", Vector2.ZERO) as Vector2)
			spawn_times.append(float(record.get("spawn_time", _get_net_time())))
		_rpc_to_connected_clients(
			&"net_enemy_spawned_batch",
			[net_ids, config_paths, positions, spawn_times]
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
	if net_id <= 0:
		return
	match reason:
		ENEMY_TERMINAL_DEFEATED:
			# A defeated enemy later emits the generic tree-exit removal. Retain only
			# this in-flight pairing marker, then consume it on REMOVED below.
			if _host_terminal_enemy_ids.has(net_id):
				return
			_host_terminal_enemy_ids[net_id] = true
		ENEMY_TERMINAL_REMOVED:
			if _host_terminal_enemy_ids.erase(net_id):
				return
		ENEMY_TERMINAL_ESCAPED:
			# GameTowerDefense suppresses the later generic removal itself, so an
			# escape must never become a session-long terminal-ID tombstone.
			_host_terminal_enemy_ids.erase(net_id)
		_:
			return
	_rpc_to_connected_clients(&"net_enemy_terminal", [net_id, reason, event_position])


func _on_host_base_health_changed(
	current_health: int,
	maximum_health: int,
	revision: int
) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(
		&"net_base_health_changed",
		[current_health, maximum_health, revision]
	)


func _on_host_tower_defense_wave_progress_changed(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_pending_wave_progress = {
		"wave_number": wave_number,
		"defeated": defeated,
		"escaped": escaped,
		"resolved": resolved,
		"total": total,
	}


func _flush_wave_progress() -> void:
	if _pending_wave_progress.is_empty():
		return
	_rpc_to_connected_clients(
		&"net_tower_defense_wave_progress_changed",
		[
			int(_pending_wave_progress.get("wave_number", 1)),
			int(_pending_wave_progress.get("defeated", 0)),
			int(_pending_wave_progress.get("escaped", 0)),
			int(_pending_wave_progress.get("resolved", 0)),
			int(_pending_wave_progress.get("total", 0)),
		]
	)
	_pending_wave_progress.clear()


func _broadcast_base_health_snapshot() -> void:
	if game == null or not game.supports_tower_defense() or not net_manager.is_host():
		return
	var snapshot := game.get_base_health_snapshot()
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
	if not is_inside_tree() or not net_manager.is_host():
		return
	var plant := game.get_multiplayer_plant_node(net_id)
	_configure_warehouse_network(plant, true)
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
	if not is_inside_tree() or not net_manager.is_host():
		return
	_send_plant_placement_rejected(requester_peer_id, request_id, reason)


func _send_plant_placement_rejected(
	requester_peer_id: int,
	request_id: int,
	reason: StringName
) -> void:
	if game == null or requester_peer_id <= 0:
		return
	if requester_peer_id == _get_local_peer_id():
		game.apply_remote_plant_placement_rejected(request_id, reason)
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
	if not is_inside_tree() or not net_manager.is_host():
		return
	var previous := _pending_plant_health_updates.get(net_id, {}) as Dictionary
	if int(previous.get("health_revision", -1)) > health_revision:
		return
	previous["current_health"] = current_health
	previous["maximum_health"] = maximum_health
	previous["health_revision"] = health_revision
	_pending_plant_health_updates[net_id] = previous


func _on_host_plant_damage_applied(
	net_id: int,
	applied_damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	world_position: Vector2
) -> void:
	if (
		not is_inside_tree()
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
		not is_inside_tree()
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


func _on_host_plant_removed(net_id: int) -> void:
	if not is_inside_tree() or not net_manager.is_host() or net_id <= 0:
		return
	if _pending_plant_health_updates.has(net_id):
		_send_pending_plant_health_updates(PackedInt32Array([net_id]))
	_pending_plant_health_updates.erase(net_id)
	_rpc_to_connected_clients(&"net_plant_removed", [net_id])


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
	return plant.export_multiplayer_runtime_state().duplicate(true)


func _apply_plant_runtime_state(
	plant: PlantDefense,
	runtime_state: Dictionary,
	host_sample_time: float
) -> void:
	if plant == null or not is_instance_valid(plant) or not is_finite(host_sample_time):
		return
	var corrected_state := runtime_state.duplicate(true)
	var mapped_sample_time := _map_host_timestamp_to_client_time(host_sample_time, false)
	var sample_age := maxf(_get_net_time() - mapped_sample_time, 0.0)
	if corrected_state.has("spread_elapsed_seconds"):
		var spread_elapsed := float(corrected_state.get("spread_elapsed_seconds", 0.0))
		if not is_finite(spread_elapsed):
			return
		corrected_state["spread_elapsed_seconds"] = maxf(spread_elapsed, 0.0) + sample_age
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


func _on_host_pickup_removed(net_id: int) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(&"net_pickup_removed", [net_id])


func _on_host_pickup_spawned(
	net_id: int,
	pickup_config: PickupConfig,
	spawn_position: Vector2
) -> void:
	if pickup_config == null or not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(
		&"net_pickup_spawned",
		[net_id, pickup_config.resource_path, spawn_position.x, spawn_position.y]
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


func _on_host_merchant_active_changed(active: bool) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	if active:
		_luoxi_offer_states_by_peer.clear()
	_rpc_to_connected_clients(&"net_merchant_active_changed", [active])


func _on_host_flow_state_changed(step_id: StringName, state: int, countdown_seconds: int) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_flush_wave_progress()
	_broadcast_wave_progress_keyframe()
	_rpc_to_connected_clients(&"net_flow_state_changed", [String(step_id), state, countdown_seconds])


func _broadcast_wave_progress_keyframe() -> void:
	if game == null or not game.supports_tower_defense():
		return
	var snapshot := game.get_tower_defense_wave_progress_snapshot()
	if snapshot.is_empty():
		return
	_rpc_to_connected_clients(
		&"net_tower_defense_wave_progress_keyframe",
		[
			int(snapshot.get("wave_number", 1)),
			int(snapshot.get("defeated", 0)),
			int(snapshot.get("escaped", 0)),
			int(snapshot.get("resolved", 0)),
			int(snapshot.get("total", 0)),
		]
	)


func _on_host_boss_started(
	net_id: int,
	boss_config: BossConfig,
	spawn_position: Vector2
) -> void:
	if not is_inside_tree() or not net_manager.is_host() or boss_config == null:
		return
	_rpc_to_connected_clients(
		&"net_boss_started",
		[net_id, boss_config.resource_path, spawn_position]
	)


func _on_host_defeat_started() -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_clear_pending_player_revives()
	_rpc_to_connected_clients(&"net_game_defeated")


func _on_host_victory_started() -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_clear_pending_player_revives()
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
	if not net_manager.is_host() or game == null:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0 or game.get_player_for_peer(sender_id) == null:
		return
	_send_runtime_state_to_peer(sender_id, include_flow_state)


@rpc("any_peer", "call_remote", "reliable", 0)
func net_terrain_snapshot_requested(known_revision: int) -> void:
	if (
		not net_manager.is_host()
		or game == null
		or not game.supports_multiplayer_terrain_state()
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
	if game == null or net_manager.is_host() or not game.supports_multiplayer_terrain_state():
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
	if not game.apply_remote_terrain_snapshot(
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
	if game == null or net_manager.is_host() or not game.supports_multiplayer_terrain_state():
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
	if not game.apply_remote_terrain_delta(revision, cell_xy, terrain_types):
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
	var enemy_id_set: Dictionary = {}
	var pickup_id_set: Dictionary = {}
	var plant_id_set: Dictionary = {}
	for net_id in live_enemy_ids:
		if net_id > 0:
			enemy_id_set[net_id] = true
	for net_id in live_pickup_ids:
		if net_id > 0:
			pickup_id_set[net_id] = true
	for net_id in live_plant_ids:
		if net_id > 0:
			plant_id_set[net_id] = true
			_clear_remote_plant_removed_marker(net_id)

	for net_id_variant in _net_enemies.keys():
		var net_id := int(net_id_variant)
		if not enemy_id_set.has(net_id):
			_remove_client_enemy(net_id, false)
	for net_id_variant in game.multiplayer_pickups.keys():
		var net_id := int(net_id_variant)
		if not pickup_id_set.has(net_id):
			net_pickup_removed(net_id)
	if game.supports_tower_defense():
		for plant_snapshot in game.get_multiplayer_plant_snapshots():
			var plant_net_id := int(plant_snapshot.get("net_id", 0))
			if plant_net_id > 0 and not plant_id_set.has(plant_net_id):
				_pending_warehouse_snapshots.erase(plant_net_id)
				_mark_remote_plant_removed(plant_net_id)
				game.apply_remote_plant_removed_silently(plant_net_id)
			elif plant_net_id > 0:
				_apply_pending_remote_plant_health(plant_net_id)
		for pending_net_id_variant in _pending_warehouse_snapshots.keys():
			var pending_net_id := int(pending_net_id_variant)
			if not plant_id_set.has(pending_net_id):
				_pending_warehouse_snapshots.erase(pending_net_id)
		for pending_net_id_variant in _pending_remote_plant_health_updates.keys():
			var pending_net_id := int(pending_net_id_variant)
			if not plant_id_set.has(pending_net_id):
				_mark_remote_plant_removed(pending_net_id)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_plant_placement_requested(
	request_id: int,
	plant_id: String,
	anchor: Vector2i
) -> void:
	if not net_manager.is_host() or game == null:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	_handle_authoritative_plant_placement_request(
		sender_id,
		request_id,
		StringName(plant_id),
		anchor
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_warehouse_command_requested(command: Dictionary) -> void:
	if not net_manager.is_host() or game == null:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	_apply_authoritative_warehouse_command(sender_id, command)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_warehouse_snapshot_requested(warehouse_net_id: int) -> void:
	if not net_manager.is_host() or game == null or warehouse_net_id <= 0:
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0 or game.get_player_for_peer(sender_id) == null:
		return
	if not _consume_peer_rate_token(
		_warehouse_snapshot_request_rate_buckets,
		sender_id,
		WAREHOUSE_SNAPSHOT_REQUEST_RATE_PER_SECOND,
		WAREHOUSE_SNAPSHOT_REQUEST_RATE_BURST
	):
		return
	var warehouse := game.get_multiplayer_plant_node(warehouse_net_id) as OakWarehouse
	if warehouse == null or not is_instance_valid(warehouse) or warehouse.is_dead:
		return
	if not net_manager.is_peer_send_ready(sender_id):
		return
	var inventory_snapshot := run_state.export_inventory_snapshot_for_peer(sender_id)
	_record_outbound_rpc(
		&"net_inventory_snapshot",
		[sender_id, inventory_snapshot, false]
	)
	net_inventory_snapshot.rpc_id(
		sender_id,
		sender_id,
		inventory_snapshot,
		false
	)
	var snapshot := warehouse.export_storage_snapshot()
	_record_outbound_rpc(
		&"net_warehouse_storage_snapshot",
		[warehouse_net_id, snapshot]
	)
	net_warehouse_storage_snapshot.rpc_id(
		sender_id,
		warehouse_net_id,
		snapshot
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_warehouse_command_result(result: Dictionary) -> void:
	if game == null:
		return
	var transaction_metric_key := _get_warehouse_transaction_metric_key(
		int(result.get("warehouse_net_id", 0)),
		int(result.get("request_id", 0))
	)
	if _warehouse_transaction_started_usec.has(transaction_metric_key):
		var started_usec := int(
			_warehouse_transaction_started_usec.get(transaction_metric_key, 0)
		)
		_warehouse_transaction_started_usec.erase(transaction_metric_key)
		if started_usec > 0:
			_runtime_network_metrics.record_transaction_latency_ms(
				float(Time.get_ticks_usec() - started_usec) / 1000.0
			)
	var warehouse_net_id := OakWarehouseProtocolScript.get_int_field(
		result,
		"warehouse_net_id",
		0
	)
	var warehouse := game.get_multiplayer_plant_node(warehouse_net_id) as OakWarehouse
	if (
		warehouse == null
		or not is_instance_valid(warehouse)
		or not warehouse.is_current_multiplayer_storage_result(result)
	):
		return
	var peer_id := OakWarehouseProtocolScript.get_int_field(result, "peer_id", 0)
	var inventory_snapshot := result.get("inventory_snapshot", {}) as Dictionary
	if peer_id > 0 and not inventory_snapshot.is_empty():
		run_state.apply_inventory_snapshot_for_peer(
			peer_id,
			inventory_snapshot
		)
	warehouse.complete_multiplayer_storage_request(result)
	var storage_snapshot := result.get("storage_snapshot", {}) as Dictionary
	if warehouse_net_id > 0 and not storage_snapshot.is_empty():
		_apply_warehouse_storage_snapshot(warehouse_net_id, storage_snapshot)


@rpc("authority", "call_remote", "reliable", 6)
func net_inventory_snapshot(
	peer_id: int,
	snapshot: Dictionary,
	force_inventory_repair: bool = false
) -> void:
	if peer_id <= 0 or snapshot.is_empty():
		return
	run_state.apply_inventory_snapshot_for_peer(
		peer_id,
		snapshot,
		force_inventory_repair
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_warehouse_storage_snapshot(warehouse_net_id: int, snapshot: Dictionary) -> void:
	_apply_warehouse_storage_snapshot(warehouse_net_id, snapshot)


func _apply_warehouse_storage_snapshot(
	warehouse_net_id: int,
	snapshot: Dictionary
) -> void:
	if game == null or warehouse_net_id <= 0 or snapshot.is_empty():
		return
	var warehouse := game.get_multiplayer_plant_node(warehouse_net_id) as OakWarehouse
	if warehouse == null or not is_instance_valid(warehouse):
		_pending_warehouse_snapshots[warehouse_net_id] = snapshot.duplicate(true)
		return
	var already_configured := (
		warehouse.multiplayer_storage_enabled
		and warehouse.warehouse_net_id == warehouse_net_id
		and warehouse.multiplayer_storage_peer_id == _get_local_peer_id()
	)
	if not already_configured:
		_configure_warehouse_network(warehouse, true)
	warehouse.apply_storage_snapshot(snapshot)


@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_spawned(
	net_id: int,
	config_path: String,
	pos_x: float,
	pos_y: float,
	host_spawn_timestamp: float
) -> void:
	if game == null or net_manager.is_host():
		return
	var existing_enemy := _get_valid_client_enemy_for_net_id(net_id)
	if (
		existing_enemy != null
		and not existing_enemy.is_dead
		and existing_enemy.config != null
		and existing_enemy.config.resource_path == config_path
	):
		return
	_remove_client_enemy(net_id, false, true)
	var enemy_config: EnemyConfig = load(config_path) as EnemyConfig
	if enemy_config == null:
		return
	var spawn_scene := enemy_config.enemy_scene
	if spawn_scene == null:
		return
	var enemy: Enemy = spawn_scene.instantiate() as Enemy
	if enemy == null:
		return
	game.enemy_container.add_child(enemy)
	var spawn_position: Vector2 = Vector2(pos_x, pos_y)
	var mapped_spawn_time: float = _map_host_timestamp_to_client_time(host_spawn_timestamp, false)
	_enemy_spawn_snapshot_times[net_id] = mapped_spawn_time
	enemy.global_position = _get_buffered_enemy_position(net_id, spawn_position)
	enemy.setup(enemy_config, game.player, game.grid_pathfinder)
	enemy.configure_multiplayer_proxy()
	enemy.set_meta("net_id", net_id)
	enemy.tree_exited.connect(_on_client_enemy_tree_exited.bind(net_id, enemy))
	_net_enemies[net_id] = enemy
	game.multiplayer_enemies_by_net_id[net_id] = enemy
	game.multiplayer_enemy_ids_by_instance[enemy.get_instance_id()] = net_id
	game.register_combat_target(net_id, enemy)
	game.play_remote_enemy_spawn_effect(spawn_position)


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
		net_enemy_spawned(
			net_ids[record_index],
			config_paths[record_index],
			positions[record_index].x,
			positions[record_index].y,
			spawn_times[record_index]
		)


@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_terminal(net_id: int, reason: int, event_position: Vector2) -> void:
	if game == null or net_manager.is_host() or net_id <= 0:
		return
	match reason:
		ENEMY_TERMINAL_DEFEATED:
			var enemy := _get_valid_client_enemy_for_net_id(net_id)
			if enemy != null and is_instance_valid(enemy):
				enemy.global_position = event_position
			_remove_client_enemy(net_id, true)
		ENEMY_TERMINAL_ESCAPED:
			game.apply_remote_enemy_escape(net_id)
			_remove_client_enemy(net_id, false)
		_:
			_remove_client_enemy(net_id, false)


@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_defeated(net_id: int, defeat_position: Vector2) -> void:
	if game == null or net_manager.is_host():
		return
	var enemy: Enemy = _get_valid_client_enemy_for_net_id(net_id)
	if enemy == null or not is_instance_valid(enemy):
		return
	enemy.global_position = defeat_position
	_remove_client_enemy(net_id, true)


@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_removed(net_id: int) -> void:
	_remove_client_enemy(net_id, true)


@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_escaped(net_id: int) -> void:
	if game == null or net_manager.is_host() or net_id <= 0:
		return
	game.apply_remote_enemy_escape(net_id)
	_remove_client_enemy(net_id, false)


@rpc("authority", "call_remote", "reliable", 5)
func net_base_health_changed(
	current_health: int,
	maximum_health: int,
	revision: int
) -> void:
	if game == null or net_manager.is_host():
		return
	game.apply_remote_base_health(current_health, maximum_health, revision)


@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_tower_defense_wave_progress_changed(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> void:
	if game == null or net_manager.is_host():
		return
	game.apply_remote_tower_defense_wave_progress(
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
	if game == null or net_manager.is_host():
		return
	_clear_remote_plant_removed_marker(net_id)
	game.apply_remote_plant_spawn(
		request_id,
		owner_peer_id,
		net_id,
		StringName(plant_id),
		anchor,
		current_health,
		maximum_health,
		health_revision
	)
	var plant := game.get_multiplayer_plant_node(net_id)
	_apply_plant_runtime_state(plant, runtime_state, host_sample_time)
	_configure_warehouse_network(plant, false)
	_apply_pending_remote_plant_health(net_id)


@rpc("authority", "call_remote", "reliable", 5)
func net_plant_placement_rejected(request_id: int, reason: String) -> void:
	if game == null or net_manager.is_host():
		return
	game.apply_remote_plant_placement_rejected(request_id, StringName(reason))


@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_plant_health_changed(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	if game == null or net_manager.is_host():
		return
	_apply_or_defer_remote_plant_health(
		net_id,
		current_health,
		maximum_health,
		health_revision
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_plant_removed(net_id: int) -> void:
	if game == null or net_manager.is_host():
		return
	_pending_warehouse_snapshots.erase(net_id)
	_mark_remote_plant_removed(net_id)
	game.apply_remote_plant_removed(net_id)


@rpc("authority", "call_remote", "unreliable_ordered", 4)
func net_plant_projectile_visual(
	spawn_position: Vector2,
	direction: Vector2,
	speed: float,
	explosion_radius: float,
	lifetime: float
) -> void:
	if (
		game == null
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


@rpc("authority", "call_remote", "unreliable_ordered", 4)
func net_corn_machine_gun_burst_batch(
	plant_net_ids: PackedInt32Array,
	action_ids: PackedInt32Array,
	directions: PackedVector2Array,
	host_action_times: PackedFloat64Array
) -> void:
	if (
		game == null
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
		var corn := game.get_multiplayer_plant_node(plant_net_ids[record_index])
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
	if game == null or net_manager.is_host():
		return
	var enemy: Enemy = _get_valid_client_enemy_for_net_id(net_id)
	if enemy == null or not is_instance_valid(enemy):
		return
	var action_sample := _push_enemy_action_interpolator_sample(
		net_id,
		action_position,
		host_action_timestamp
	)
	if not bool(action_sample.get("accepted", false)):
		return
	if action_sample.get("apply_direct_position", false):
		enemy.global_position = action_position
	if enemy.has_method("play_multiplayer_enemy_action"):
		enemy.call("play_multiplayer_enemy_action", StringName(action_name), direction, action_id)


@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_enemy_target_action(
	net_id: int,
	action_name: String,
	target_peer_id: int,
	action_position: Vector2,
	action_id: int,
	host_action_timestamp: float = -1.0
) -> void:
	if game == null or net_manager.is_host():
		return
	var enemy: Enemy = _get_valid_client_enemy_for_net_id(net_id)
	if enemy == null or not is_instance_valid(enemy):
		return
	var action_sample := _push_enemy_action_interpolator_sample(
		net_id,
		action_position,
		host_action_timestamp
	)
	if not bool(action_sample.get("accepted", false)):
		return
	if action_sample.get("apply_direct_position", false):
		enemy.global_position = action_position
	var target := game.get_player_for_peer(target_peer_id)
	if enemy.has_method("play_multiplayer_enemy_target_action"):
		enemy.call(
			"play_multiplayer_enemy_target_action",
			StringName(action_name),
			target,
			action_id
		)


func _push_enemy_action_interpolator_sample(
	net_id: int,
	action_position: Vector2,
	host_action_timestamp: float
) -> Dictionary:
	if net_id <= 0:
		return {}
	var action_time := _get_net_time()
	if host_action_timestamp >= 0.0:
		action_time = _map_host_timestamp_to_client_time(host_action_timestamp, false)
	var interp := enemy_interpolators.get(net_id) as NetInterpolator
	var had_interpolator_samples := interp != null and interp.get_buffer_size() > 0
	if interp != null:
		var latest_timestamp := interp.get_latest_timestamp()
		if latest_timestamp > 0.0 and action_time < latest_timestamp:
			if latest_timestamp - action_time > ENEMY_ACTION_SNAPSHOT_REORDER_TOLERANCE_SECONDS:
				return {"accepted": false, "apply_direct_position": false}
			return {"accepted": true, "apply_direct_position": false}
	else:
		interp = _create_enemy_interpolator()
		enemy_interpolators[net_id] = interp
	interp.push_snapshot(action_time, action_position, Vector2.ZERO)
	return {"accepted": true, "apply_direct_position": not had_interpolator_samples}



func _on_client_enemy_tree_exited(net_id: int, exiting_enemy: Enemy) -> void:
	var enemy_variant: Variant = _net_enemies.get(net_id)
	if enemy_variant == null:
		return
	if is_instance_valid(enemy_variant) and enemy_variant != exiting_enemy:
		return
	_net_enemies.erase(net_id)
	_enemy_spawn_snapshot_times.erase(net_id)
	enemy_interpolators.erase(net_id)
	_offscreen_enemy_interpolation_slots.erase(net_id)
	if game != null:
		game.multiplayer_enemies_by_net_id.erase(net_id)
		game.multiplayer_enemy_ids_by_instance.erase(exiting_enemy.get_instance_id())
		game.unregister_combat_target(net_id)

func _get_buffered_enemy_position(net_id: int, fallback_position: Vector2) -> Vector2:
	var interp: NetInterpolator = enemy_interpolators.get(net_id) as NetInterpolator
	if interp == null or interp.get_buffer_size() <= 0:
		return fallback_position
	return interp.get_interpolated_position(_get_net_time())


func _reconcile_enemy_roster(seen_enemy_ids: Dictionary, snapshot_time: float) -> void:
	var stale_ids: Array[int] = []
	for net_id_variant in _net_enemies:
		var net_id := int(net_id_variant)
		if seen_enemy_ids.has(net_id):
			continue
		var spawn_time := float(_enemy_spawn_snapshot_times.get(net_id, -INF))
		if spawn_time > snapshot_time:
			continue
		stale_ids.append(net_id)
	for net_id in stale_ids:
		# Snapshot roster reconciliation is recovery, not a death event. Explicit
		# reliable defeat/removal RPCs own death presentation; a leaked Home enemy
		# must disappear silently even if the state channel arrives first.
		_remove_client_enemy(net_id, false)


func _remove_client_enemy(
	net_id: int,
	play_death_sequence: bool,
	preserve_interpolator: bool = false
) -> void:
	var enemy_variant: Variant = _net_enemies.get(net_id)
	if enemy_variant != null and is_instance_valid(enemy_variant):
		var enemy: Enemy = enemy_variant as Enemy
		if enemy != null:
			if play_death_sequence:
				enemy.play_multiplayer_death_sequence()
			else:
				enemy.queue_free()
	_net_enemies.erase(net_id)
	_enemy_spawn_snapshot_times.erase(net_id)
	if game != null:
		game.multiplayer_enemies_by_net_id.erase(net_id)
		game.unregister_combat_target(net_id)
		if enemy_variant != null and is_instance_valid(enemy_variant):
			var enemy_for_instance := enemy_variant as Enemy
			if enemy_for_instance != null:
				game.multiplayer_enemy_ids_by_instance.erase(enemy_for_instance.get_instance_id())
	if not preserve_interpolator:
		enemy_interpolators.erase(net_id)
	_offscreen_enemy_interpolation_slots.erase(net_id)

@rpc("authority", "call_remote", "reliable", 5)
func net_pickup_removed(net_id: int) -> void:
	if game == null or net_manager.is_host():
		return
	var pickup: Pickup = game.get_pickup_for_net_id(net_id)
	if pickup == null or not is_instance_valid(pickup):
		game.multiplayer_pickups.erase(net_id)
		return
	game.multiplayer_pickups.erase(net_id)
	pickup.queue_free()


@rpc("authority", "call_remote", "reliable", 5)
func net_pickup_spawned(net_id: int, config_path: String, pos_x: float, pos_y: float) -> void:
	if game == null or net_manager.is_host():
		return
	if game.get_pickup_for_net_id(net_id) != null:
		return
	var pickup_config := load(config_path) as PickupConfig
	if pickup_config == null:
		return
	var pickup := PICKUP_SCENE.instantiate() as Pickup
	if pickup == null:
		return
	pickup.config = pickup_config
	game.enemy_container.add_child(pickup)
	pickup.global_position = Vector2(pos_x, pos_y)
	pickup.set_meta("net_id", net_id)
	pickup.collision_layer = 0
	pickup.collision_mask = 0
	game.multiplayer_pickups[net_id] = pickup


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
		run_state.apply_inventory_snapshot_for_peer(
			collector_peer_id,
			inventory_snapshot
		)


@rpc("authority", "call_remote", "reliable", 5)
func net_merchant_active_changed(active: bool) -> void:
	if game == null or net_manager.is_host():
		return
	game.apply_remote_merchant_active(active)



@rpc("authority", "call_remote", "reliable", 5)
func net_flow_state_changed(step_id: String, state: int, countdown_seconds: int) -> void:
	if game == null or net_manager.is_host():
		return
	_client_has_received_flow_state = true
	# The same count can need to repaint a newly entered wave/HUD state. Invalidate
	# the render-frame cache at every authoritative flow transition.
	_last_applied_remote_enemy_count = -1
	game.apply_remote_flow_state(StringName(step_id), state, countdown_seconds)


@rpc("authority", "call_remote", "reliable", 5)
func net_boss_started(net_id: int, boss_config_path: String, spawn_position: Vector2) -> void:
	if game == null or net_manager.is_host():
		return
	var boss_config := load(boss_config_path) as BossConfig
	if boss_config == null:
		return
	game.apply_remote_boss_started(net_id, boss_config, spawn_position)
	var boss_enemy := game.get_enemy_for_net_id(net_id) as Enemy
	if boss_enemy != null and is_instance_valid(boss_enemy):
		_net_enemies[net_id] = boss_enemy
		if not boss_enemy.tree_exited.is_connected(_on_client_enemy_tree_exited.bind(net_id, boss_enemy)):
			boss_enemy.tree_exited.connect(_on_client_enemy_tree_exited.bind(net_id, boss_enemy))


@rpc("authority", "call_remote", "reliable", 5)
func net_game_defeated() -> void:
	if game == null or net_manager.is_host():
		return
	_clear_pending_player_revives()
	game.apply_remote_defeat()


@rpc("authority", "call_remote", "reliable", 5)
func net_game_victory() -> void:
	if game == null or net_manager.is_host():
		return
	_clear_pending_player_revives()
	game.apply_remote_victory()


@rpc("any_peer", "call_remote", "reliable", 6)
func net_upgrade_selected(stat_type: int) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	_apply_upgrade_for_peer(sender_id, stat_type)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_inventory_item_use_requested(
	slot_index: int,
	expected_inventory_revision: int = -1
) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	if expected_inventory_revision < 0:
		# An omitted revision is converted to an impossible future revision so a
		# remote caller can never bypass optimistic concurrency.
		expected_inventory_revision = (
			run_state.get_inventory_revision_for_peer(sender_id) + 1
		)
	_apply_inventory_item_use_for_peer(
		sender_id,
		slot_index,
		expected_inventory_revision
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_inventory_item_discard_requested(
	slot_index: int,
	expected_inventory_revision: int = -1
) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	if expected_inventory_revision < 0:
		# Keep the default callable for direct tests, but never let a remote peer
		# bypass optimistic concurrency by omitting the revision.
		expected_inventory_revision = (
			run_state.get_inventory_revision_for_peer(sender_id) + 1
		)
	_apply_inventory_item_discard_for_peer(
		sender_id,
		slot_index,
		expected_inventory_revision
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_skill1_purchase_requested() -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	_apply_skill1_purchase_for_peer(sender_id)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_tower_defense_start_wave_requested() -> void:
	if not net_manager.is_host() or game == null or not game.supports_tower_defense():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0 or game.get_player_for_peer(sender_id) == null:
		return
	game.request_tower_defense_wave_start(sender_id)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_collectible_offer_requested() -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
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
	_apply_luoxi_collectible_refresh_for_peer(sender_id, offer_revision, true)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_cheat_xirang_requested() -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
		return
	_apply_cheat_xirang_for_peer(sender_id)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_debug_collectible_requested(config_path: String) -> void:
	if not net_manager.is_host():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= 0:
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
	if not success:
		return
	if peer_id <= 0 or game == null:
		return
	var player_node: Player = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	run_state.ensure_multiplayer_peer_state(peer_id)
	run_state.set_upgrade_level_for_peer(peer_id, stat_type, level)
	var already_applied_on_host: bool = net_manager.is_host() and peer_id == _get_local_peer_id()
	if not already_applied_on_host:
		_apply_confirmed_upgrade_to_player(player_node, stat_type)
	player_node.current_xirang = current_xirang
	player_node.xirang_changed.emit(current_xirang, 0)
	if free_upgrade and not already_applied_on_host:
		player_node.play_lucky_upgrade_feedback()


@rpc("authority", "call_remote", "reliable", 6)
func net_inventory_item_used(
	peer_id: int,
	slot_index: int,
	config_path: String,
	success: bool,
	inventory_snapshot: Dictionary = {},
	force_inventory_repair: bool = false
) -> void:
	if peer_id <= 0 or game == null:
		return
	var player_node: Player = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	var already_applied_on_host: bool = net_manager.is_host() and peer_id == _get_local_peer_id()
	var inventory_revision_before := run_state.get_inventory_revision_for_peer(peer_id)
	var snapshot_applied := false
	if not inventory_snapshot.is_empty():
		snapshot_applied = run_state.apply_inventory_snapshot_for_peer(
			peer_id,
			inventory_snapshot,
			force_inventory_repair
		)
	if not success or already_applied_on_host:
		return
	if inventory_snapshot.is_empty():
		# Compatibility for confirmations produced before authoritative snapshots.
		run_state.try_use_item_for_peer(peer_id, slot_index, player_node)
		return
	var snapshot_revision := int(inventory_snapshot.get("revision", -1))
	if (
		snapshot_applied
		and snapshot_revision > inventory_revision_before
		and not config_path.is_empty()
	):
		var item := load(config_path) as PickupConfig
		if item != null:
			player_node.apply_pickup(item, false)


@rpc("authority", "call_remote", "reliable", 6)
func net_inventory_item_discarded(
	peer_id: int,
	slot_index: int,
	success: bool,
	inventory_snapshot: Dictionary = {},
	force_inventory_repair: bool = false
) -> void:
	if peer_id <= 0 or game == null:
		return
	var player_node: Player = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if not inventory_snapshot.is_empty():
		run_state.apply_inventory_snapshot_for_peer(
			peer_id,
			inventory_snapshot,
			force_inventory_repair
		)
	if not success:
		return
	if inventory_snapshot.is_empty():
		# Compatibility for confirmations produced before authoritative snapshots.
		run_state.discard_item_for_peer(peer_id, slot_index)


func _apply_confirmed_upgrade_to_player(player_node: Player, stat_type: int) -> void:
	match stat_type:
		RunStateStore.StatType.ATTACK:
			player_node.upgrade_attack()
		RunStateStore.StatType.HEALTH:
			player_node.upgrade_max_health()
		RunStateStore.StatType.ATTACK_SPEED:
			player_node.upgrade_attack_speed()
		RunStateStore.StatType.DODGE:
			player_node.upgrade_dodge()


@rpc("authority", "call_remote", "reliable", 6)
func net_skill1_purchase_confirmed(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	result_code: int,
	skill1_upgrade_level: int = -1,
	skill1_charge_duration: float = -1.0
) -> void:
	if game == null:
		return
	game.apply_skill1_purchase_state(
		peer_id,
		current_xirang,
		skill1_unlocked,
		skill1_upgrade_level,
		skill1_charge_duration
	)
	if peer_id == _get_local_peer_id():
		game.show_local_skill1_purchase_result(result_code)


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
	if game == null:
		return
	if not inventory_snapshot.is_empty():
		run_state.apply_inventory_snapshot_for_peer(peer_id, inventory_snapshot)
	if result_code == LuoxiMerchant.COLLECTIBLE_RESULT_SUCCESS and not config_path.is_empty():
		var already_applied_on_host: bool = net_manager.is_host() and peer_id == _get_local_peer_id()
		if not already_applied_on_host:
			game.record_luoxi_collectible_claim(peer_id)
			if inventory_snapshot.is_empty():
				var item := load(config_path) as PickupConfig
				if item != null:
					run_state.try_add_item_for_peer(peer_id, item)
	elif result_code == LuoxiMerchant.COLLECTIBLE_RESULT_ALREADY_CLAIMED:
		game.mark_luoxi_collectible_claimed(peer_id)
	if peer_id == _get_local_peer_id():
		if result_code == LuoxiMerchant.COLLECTIBLE_RESULT_STALE_OFFER:
			return
		game.show_local_luoxi_collectible_result(result_code)


@rpc("authority", "call_remote", "reliable", 6)
func net_luoxi_collectible_refresh_confirmed(
	peer_id: int,
	result_code: int,
	refresh_count: int,
	current_xirang: int
) -> void:
	if game == null:
		return
	var player_node: Player = game.get_player_for_peer(peer_id)
	if player_node != null and is_instance_valid(player_node):
		var already_applied_on_host: bool = net_manager.is_host() and peer_id == _get_local_peer_id()
		if not already_applied_on_host:
			var xirang_delta := current_xirang - player_node.current_xirang
			player_node.current_xirang = maxi(current_xirang, 0)
			player_node.xirang_changed.emit(player_node.current_xirang, xirang_delta)
	if peer_id == _get_local_peer_id():
		game.show_local_luoxi_refresh_result(result_code, refresh_count, current_xirang)


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
		game.show_debug_collectible_grant_result(config_path, success)


func _apply_upgrade_for_peer(peer_id: int, stat_type: int) -> void:
	if game == null or peer_id <= 0:
		return
	var player_node: Player = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	var success := run_state.try_upgrade_for_peer(peer_id, stat_type, player_node)
	var free_upgrade := success and player_node.consume_last_base_upgrade_free_flag()
	var level := run_state.get_upgrade_level_for_peer(peer_id, stat_type)
	var current_xirang := player_node.current_xirang
	_rpc_to_connected_clients(
		&"net_upgrade_confirmed",
		[peer_id, stat_type, level, current_xirang, success, free_upgrade]
	)
	if peer_id == _get_local_peer_id():
		net_upgrade_confirmed(peer_id, stat_type, level, current_xirang, success, free_upgrade)


func _apply_inventory_item_use_for_peer(
	peer_id: int,
	slot_index: int,
	expected_inventory_revision: int = -1
) -> void:
	if game == null or peer_id <= 0:
		return
	var player_node: Player = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	var current_revision := run_state.get_inventory_revision_for_peer(peer_id)
	var revision_mismatch := (
		expected_inventory_revision >= 0
		and expected_inventory_revision != current_revision
	)
	var item := run_state.get_item_for_peer(peer_id, slot_index)
	var config_path := item.resource_path if item != null else ""
	var success := (
		not revision_mismatch
		and run_state.try_use_item_for_peer(peer_id, slot_index, player_node)
	)
	if not success:
		config_path = ""
	var inventory_snapshot := run_state.export_inventory_snapshot_for_peer(peer_id)
	_rpc_to_connected_clients(
		&"net_inventory_item_used",
		[
			peer_id,
			slot_index,
			config_path,
			success,
			inventory_snapshot,
			revision_mismatch,
		]
	)
	if peer_id == _get_local_peer_id():
		net_inventory_item_used(
			peer_id,
			slot_index,
			config_path,
			success,
			inventory_snapshot,
			revision_mismatch
		)


func _apply_inventory_item_discard_for_peer(
	peer_id: int,
	slot_index: int,
	expected_inventory_revision: int = -1
) -> void:
	if game == null or peer_id <= 0:
		return
	var player_node: Player = game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	var current_revision := run_state.get_inventory_revision_for_peer(peer_id)
	var revision_mismatch := (
		expected_inventory_revision >= 0
		and expected_inventory_revision != current_revision
	)
	var success := (
		not revision_mismatch
		and run_state.discard_item_for_peer(peer_id, slot_index)
	)
	var inventory_snapshot := run_state.export_inventory_snapshot_for_peer(peer_id)
	_rpc_to_connected_clients(
		&"net_inventory_item_discarded",
		[
			peer_id,
			slot_index,
			success,
			inventory_snapshot,
			revision_mismatch,
		]
	)
	if peer_id == _get_local_peer_id():
		net_inventory_item_discarded(
			peer_id,
			slot_index,
			success,
			inventory_snapshot,
			revision_mismatch
		)


func _apply_skill1_purchase_for_peer(peer_id: int) -> void:
	if game == null or peer_id <= 0:
		return
	var player_node := game.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	var result_code := game.try_purchase_skill1_for_peer(peer_id)
	var current_xirang := player_node.current_xirang
	var skill1_unlocked := player_node.has_skill1()
	var skill1_upgrade_level := player_node.skill1_upgrade_level
	var skill1_charge_duration := player_node.skill1_charge_duration
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
		net_skill1_purchase_confirmed(
			peer_id,
			current_xirang,
			skill1_unlocked,
			result_code,
			skill1_upgrade_level,
			skill1_charge_duration
		)


func _get_luoxi_merchant() -> LuoxiMerchant:
	if game == null:
		return null
	return game.get("luoxi_merchant") as LuoxiMerchant


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
	if game == null or peer_id <= 0 or game.has_luoxi_collectible_claimed(peer_id):
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
		"refresh_count": game.get_luoxi_collectible_refresh_count(peer_id),
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
		state.get("refresh_count", game.get_luoxi_collectible_refresh_count(peer_id))
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
			LuoxiMerchant.COLLECTIBLE_RESULT_INVALID_PLAYER,
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
			LuoxiMerchant.COLLECTIBLE_RESULT_STALE_OFFER,
			authoritative_revision
		)
		return

	var config_paths := state.get("config_paths", []) as Array
	if choice_index < 0 or choice_index >= config_paths.size():
		_send_luoxi_collectible_confirmation(
			peer_id,
			choice_index,
			"",
			LuoxiMerchant.COLLECTIBLE_RESULT_INVALID_PLAYER,
			authoritative_revision
		)
		return
	var resolved_config_path := str(config_paths[choice_index])
	var result_code := game.try_claim_luoxi_collectible_for_peer(
		peer_id,
		resolved_config_path
	)
	if result_code != LuoxiMerchant.COLLECTIBLE_RESULT_SUCCESS:
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
			LuoxiMerchant.REFRESH_RESULT_STALE_OFFER
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
			LuoxiMerchant.REFRESH_RESULT_INVALID_PLAYER
		)
		return
	var result_code := game.try_refresh_luoxi_collectibles_for_peer(peer_id)
	if result_code == LuoxiMerchant.REFRESH_RESULT_SUCCESS:
		state = _commit_luoxi_offer_state(peer_id, replacement_paths)
	else:
		state["refresh_count"] = game.get_luoxi_collectible_refresh_count(peer_id)
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
	if game == null:
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
	if game == null or peer_id <= 0:
		return
	var item := LuoxiMerchant.get_collectible_for_path(config_path)
	var success := false
	if item != null:
		success = run_state.try_add_item_for_peer(peer_id, item)
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
		or game == null
		or not game.supports_multiplayer_terrain_state()
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
		or game == null
		or not game.supports_multiplayer_terrain_state()
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
		_client_host_game_ready = true
		if game != null:
			game.activate_runtime()
		if net_manager.is_client():
			_request_runtime_state_from_host()


func _on_net_player_left(peer_id: int) -> void:
	if peer_id <= 0:
		return
	_clear_peer_network_state(peer_id)
	if game != null and game.has_method("remove_multiplayer_player"):
		game.call("remove_multiplayer_player", peer_id)


func _clear_peer_network_state(peer_id: int) -> void:
	var active_tiyi_activation_id := int(_active_tiyi_activations_by_peer.get(peer_id, 0))
	if active_tiyi_activation_id > 0 and net_manager != null and net_manager.is_host():
		_cancel_authoritative_tiyi_high_noon(peer_id, active_tiyi_activation_id, true)
	snapshot_mgr.clear_peer_delta_cache(peer_id)
	_player_snapshot_cohort_peers.erase(peer_id)
	_enemy_snapshot_cohort_peers.erase(peer_id)
	_last_player_keyframe_time_by_peer.erase(peer_id)
	_last_enemy_keyframe_time_by_peer.erase(peer_id)
	if _player_snapshot_cohort_peers.is_empty():
		snapshot_mgr.clear_player_send_baseline(SHARED_SNAPSHOT_COHORT_ID)
	if _enemy_snapshot_cohort_peers.is_empty():
		snapshot_mgr.clear_enemy_send_baseline(SHARED_SNAPSHOT_COHORT_ID)
	_last_plant_placement_request_ids.erase(peer_id)
	player_visual_interpolators.erase(peer_id)
	_last_player_state_sequences.erase(peer_id)
	_last_dash_request_sequences.erase(peer_id)
	_last_dash_confirmed_sequences.erase(peer_id)
	_last_dash_accepted_times.erase(peer_id)
	_player_character_mismatch_warnings.erase(peer_id)
	_hoe_action_sequences_by_peer.erase(peer_id)
	_last_hoe_action_request_ids.erase(peer_id)
	_tiyi_activation_sequences_by_peer.erase(peer_id)
	_active_tiyi_activations_by_peer.erase(peer_id)
	_tiyi_target_ids_by_peer.erase(peer_id)
	_last_tiyi_activation_seen_by_peer.erase(peer_id)
	_accepted_player_state_positions.erase(peer_id)
	_accepted_player_state_times.erase(peer_id)
	_host_latest_client_player_snapshot_states.erase(peer_id)
	_player_health_revisions.erase(peer_id)
	_dead_player_revive_times.erase(peer_id)
	_dead_player_revive_last_seconds.erase(peer_id)
	_luoxi_offer_states_by_peer.erase(peer_id)
	_luoxi_offer_revision_counters.erase(peer_id)
	_plant_placement_rate_buckets.erase(peer_id)
	_client_projectile_request_rate_buckets.erase(peer_id)
	_warehouse_transaction_rate_buckets.erase(peer_id)
	_warehouse_snapshot_request_rate_buckets.erase(peer_id)
	_terrain_snapshot_request_rate_buckets.erase(peer_id)
	_warehouse_transaction_results_by_peer.erase(peer_id)
	_clear_projectiles_for_peer(peer_id)
	_clear_projectile_records_for_peer(peer_id)


func _clear_projectiles_for_peer(peer_id: int) -> void:
	var projectile_ids: Array[int] = []
	for projectile_id_variant in _known_projectiles.keys():
		var projectile_id := int(projectile_id_variant)
		var projectile_variant: Variant = _known_projectiles.get(projectile_id)
		if projectile_variant == null or not is_instance_valid(projectile_variant):
			projectile_ids.append(projectile_id)
			continue
		var projectile_object := projectile_variant as Object
		if projectile_object == null:
			projectile_ids.append(projectile_id)
			continue
		var projectile_owner := int(projectile_object.get("owner_peer_id"))
		if projectile_owner == peer_id:
			projectile_ids.append(projectile_id)
	for projectile_id in projectile_ids:
		var projectile_variant: Variant = _known_projectiles.get(projectile_id)
		_known_projectiles.erase(projectile_id)
		if projectile_variant != null and is_instance_valid(projectile_variant):
			var projectile_node := projectile_variant as Node
			if projectile_node != null:
				if projectile_node.has_method("retire"):
					projectile_node.call("retire")
				else:
					projectile_node.queue_free()


func _clear_projectile_records_for_peer(peer_id: int) -> void:
	var projectile_ids: Array[int] = []
	for projectile_id_variant in _projectile_records.keys():
		var projectile_id := int(projectile_id_variant)
		var record := _projectile_records[projectile_id] as Dictionary
		if record.is_empty() or int(record.get("owner_peer_id", 0)) == peer_id:
			projectile_ids.append(projectile_id)
	for projectile_id in projectile_ids:
		_projectile_records.erase(projectile_id)


func _return_to_lobby() -> void:
	snapshot_mgr.reset_delta_cache()
	_player_snapshot_cohort_peers.clear()
	_enemy_snapshot_cohort_peers.clear()
	_player_snapshot_encode_count = 0
	_enemy_snapshot_chunk_encode_count = 0
	_pending_enemy_snapshot_batches.clear()
	_processed_collectible_effect_event_ids.clear()
	_last_completed_enemy_snapshot_batch_id = 0
	_latest_enemy_snapshot_batch_seen = 0
	_pending_enemy_damage_feedback.clear()
	_pending_plant_health_updates.clear()
	_clear_remote_plant_health_state()
	_pending_wave_progress.clear()
	_pending_enemy_spawns.clear()
	_host_terminal_enemy_ids.clear()
	_pending_terrain_snapshot_batches.clear()
	_terrain_snapshot_request_rate_buckets.clear()
	_client_projectile_request_rate_buckets.clear()
	_client_terrain_revision = -1
	_last_host_terrain_revision_broadcast = 0
	_client_has_terrain_snapshot = false
	_client_waiting_for_terrain_snapshot = false
	_terrain_snapshot_repair_watchdog_time_left = 0.0
	_last_completed_terrain_snapshot_id = 0
	_luoxi_offer_states_by_peer.clear()
	_luoxi_offer_revision_counters.clear()
	_warehouse_snapshot_request_rate_buckets.clear()
	_warehouse_transaction_started_usec.clear()
	_last_player_keyframe_time_by_peer.clear()
	_last_enemy_keyframe_time_by_peer.clear()
	_player_character_mismatch_warnings.clear()
	_hoe_action_sequences_by_peer.clear()
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	tree.change_scene_to_file("res://scene/multiplayer/multiplayer_lobby.tscn")
