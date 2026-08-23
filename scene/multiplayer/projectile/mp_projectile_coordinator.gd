extends Node
class_name MpProjectileCoordinator

signal rpc_to_host_requested(method_name: StringName, arguments: Array)
signal rpc_broadcast_requested(method_name: StringName, arguments: Array)
signal rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	arguments: Array
)
signal enemy_rapid_fire_action_requested(
	source_enemy_id: int,
	profile: int,
	direction: Vector2,
	source_position: Vector2,
	action_id: int,
	host_action_timestamp: float,
	action_elapsed: float
)

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const EnemyRapidFireNetworkCodecScript := preload(
	"res://scene/multiplayer/projectile/enemy_rapid_fire_network_codec.gd"
)

const BULLET_SCENE_PATH := "res://scene/combat/projectiles/bullet.tscn"
const TANGO_LASER_BULLET_SCENE_PATH := (
	"res://scene/player/tango/tango_laser_bullet.tscn"
)
const TIYI_SNIPER_BULLET_SCENE_PATH := (
	"res://scene/player/tiyi/tiyi_sniper_bullet.tscn"
)
const TIYI_SNIPER_HIT_EFFECT_SCENE_PATH := (
	"res://scene/player/tiyi/tiyi_sniper_hit_effect.tscn"
)
const COLLECTIBLE_ARROW_PROJECTILE_SCENE := preload(
	"res://scene/combat/collectibles/collectible_arrow_projectile.tscn"
)
const SKILL1_BOMB_SCENE_PATH := (
	"res://scene/player/weishidaier/weishidaier_skill1_bomb.tscn"
)
const CAPOO_AK47_BULLET_SCENE := preload(
	"res://scene/enemy/capoo/capoo_ak47_bullet.tscn"
)
const COMBAT_ROBOT_GUNNER_BULLET_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_gunner_bullet.tscn"
)
const COMBAT_ROBOT_GUNNER_ELITE_BULLET_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_gunner_elite_bullet.tscn"
)
const COMBAT_ROBOT_SUICIDE_DRONE_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone.tscn"
)
const COMBAT_ROBOT_SUICIDE_DRONE_ELITE_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone_elite.tscn"
)
const CAPOO_RPG_ROCKET_SCENE := preload(
	"res://scene/enemy/capoo/capoo_rpg_rocket.tscn"
)
const CAPOO_MAGE_FIREBALL_SCENE := preload(
	"res://scene/enemy/capoo/capoo_mage_fireball.tscn"
)
const FIRE_SORCERER_FIREBALL_VOLLEY_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer_fireball_volley.tscn"
)
const FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer_elite_fireball_volley.tscn"
)
const CAPOO_SMG_BULLET_SCENE := preload(
	"res://scene/enemy/capoo/capoo_smg_bullet.tscn"
)
const YUANSHI_FIRE_PROJECTILE_SCENE := preload(
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_fire_projectile.tscn"
)
const FROST_SORCERER_ICE_SPIKE_SCENE := preload(
	"res://scene/enemy/sorcerer/frost_sorcerer_ice_spike.tscn"
)
const LINGLAN_SAKURA_BULLET_SCENE_PATH := (
	"res://scene/boss/linglan/linglan_skill1_sakura_bullet.tscn"
)
const LINGLAN_SKILL2_CONFIG_PATH := (
	"res://resources/config/bosses/linglan_skill2.tres"
)
const LINGLAN_SKILL2_ROCKET_SCENE_PATH := (
	"res://scene/boss/linglan/linglan_skill2_sakura_rocket.tscn"
)
const COLLECTIBLE_SAKURA_ROCKET_SCENE_PATH := (
	"res://scene/combat/collectibles/collectible_sakura_rocket.tscn"
)
const LINGLAN_SKILL3_CONFIG_PATH := (
	"res://resources/config/bosses/linglan_skill3.tres"
)
const LINGLAN_SKILL3_ORB_SCENE_PATH := (
	"res://scene/boss/linglan/linglan_skill3_light_orb.tscn"
)
const LINGLAN_SKILL4_CONFIG_PATH := (
	"res://resources/config/bosses/linglan_skill4.tres"
)
const LINGLAN_SKILL4_ORB_SCENE_PATH := (
	"res://scene/boss/linglan/linglan_skill4_light_orb.tscn"
)

const PROJECTILE_RECORD_RETENTION_SECONDS := 5.0
const DAMAGE_SOURCE_SNAPSHOT_META := &"damage_source_snapshot"
const PROJECTILE_ID_SEQUENCE_BITS := 32
const PROJECTILE_ID_SEQUENCE_MASK: int = 0xFFFFFFFF
const PROJECTILE_ID_HOST_ORIGIN_BIT: int = 0x80000000
const PROJECTILE_ID_SEQUENCE_COUNTER_MASK: int = 0x7FFFFFFF
const PROJECTILE_ID_MAX_OWNER_PEER_ID: int = 0x7FFFFFFF
const PROJECTILE_ID_FALLBACK_OWNER_PEER_ID := 999999
const CLIENT_PROJECTILE_DIRECTION_MIN_LENGTH := 0.2
const CLIENT_PROJECTILE_DIRECTION_MAX_LENGTH := 1.5
const CLIENT_PROJECTILE_REQUEST_RATE_PER_SECOND := 256.0
const CLIENT_PROJECTILE_REQUEST_RATE_BURST := 64.0
const PROJECTILE_TIME_COMPENSATION_MAX_SECONDS := 0.25
const HIT_DEDUP_RETENTION_SECONDS := 30.0
const FIRE_SORCERER_FIREBALL_VOLLEY_TYPE: StringName = (
	&"fire_sorcerer_fireball_volley"
)
const FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_TYPE: StringName = (
	&"fire_sorcerer_elite_fireball_volley"
)
const FIRE_SORCERER_CONSUMED_SOURCE_MASK_KEY: StringName = (
	&"fire_sorcerer_consumed_source_mask"
)
const FIRE_SORCERER_VOLLEY_LOCAL_OFFSETS: Array[Vector2] = [
	Vector2(24.0, 1.0),
	Vector2(15.0, -5.0),
	Vector2(23.0, 13.0),
]
const FIRE_SORCERER_VOLLEY_HOMING_TURN_RATE := 6.0
const FIRE_SORCERER_VOLLEY_BURN_DURATION := 5.0
const FIRE_SORCERER_NORMAL_BURN_LEVEL := 5
const FIRE_SORCERER_ELITE_BURN_LEVEL := 10
const FROST_SORCERER_ICE_SPIKE_TYPE: StringName = &"frost_sorcerer_ice_spike"
const COMBAT_ROBOT_SUICIDE_DRONE_TYPE: StringName = &"combat_robot_suicide_drone"
const COMBAT_ROBOT_SUICIDE_DRONE_ELITE_TYPE: StringName = (
	&"combat_robot_suicide_drone_elite"
)
const TIYI_SNIPER_PROJECTILE_TYPE: StringName = &"tiyi_sniper_bullet"
const TANGO_LASER_PROJECTILE_TYPE: StringName = &"tango_laser_bullet"
const TANGO_LASER_VOLLEY_PROJECTILE_COUNT := 3
const LINGLAN_SKILL1_RING_MAX_PROJECTILES_PER_PACKET := 32
const CLIENT_PROJECTILE_SPAWN_POSITION_TOLERANCE := 224.0
const TANGO_NETWORK_BARRAGE_MAXIMUM_SECONDS := 5.0
const ENEMY_RAPID_FIRE_SNAPSHOT_MAX_DESCRIPTOR_BYTES := 960
const ENEMY_RAPID_FIRE_SNAPSHOT_MAX_PROJECTILES_PER_CHUNK := 28
const ENEMY_RAPID_FIRE_BURST_MAX_DESCRIPTOR_BYTES := (
	EnemyRapidFireNetworkCodecScript.MAX_BURST_PAYLOAD_BYTES
)
const ENEMY_RAPID_FIRE_MAX_RESERVATION_COUNT := 4096
const ENEMY_RAPID_FIRE_REPLICA_DEDUP_RETENTION_SECONDS := 5.0
const ENEMY_RAPID_FIRE_FINISH_DEDUP_RETENTION_SECONDS := 30.0
const ENEMY_RAPID_FIRE_TERMINAL_SOURCE_RETENTION_SECONDS := 30.0
const ENEMY_RAPID_FIRE_MAX_PENDING_SNAPSHOTS := 4
const ENEMY_RAPID_FIRE_MAX_SNAPSHOT_CHUNKS := 256
const ENEMY_RAPID_FIRE_FINISH_MAX_DESCRIPTOR_BYTES := 960
const ENEMY_RAPID_FIRE_FINISH_REASON_CANCELLED := 4


class EnemyHitAdmission:
	extends RefCounted

	var projectile_type: StringName = &""
	var authoritative_damage := -1
	var consumes_first_confirmed_hit := false


var _runtime: CombatRuntimeBase = null
var _net_manager: NetManagerStore = null
var _player_coordinator: MpPlayerCoordinator = null
var _get_net_time_callable := Callable()
var _get_host_event_age_callable := Callable()
var _is_embedded_participant_suspended_callable := Callable()
var _runtime_scene_cache: Dictionary = {}
var _projectile_default_parameter_cache: Dictionary[StringName, Dictionary] = {}
var _linglan_sakura_bullet_scene: PackedScene = null
var _linglan_skill2_config: Resource = null
var _linglan_skill2_rocket_scene: PackedScene = null
var _collectible_sakura_rocket_scene: PackedScene = null
var _linglan_skill3_config: Resource = null
var _linglan_skill3_orb_scene: PackedScene = null
var _linglan_skill4_config: Resource = null
var _linglan_skill4_orb_scene: PackedScene = null
var _next_projectile_sequence := 1
var _known_projectiles: Dictionary = {}
var _known_data_projectile_services: Dictionary[int, RapidFireSimulationService] = {}
var _known_data_projectile_handles: Dictionary[int, int] = {}
var _known_data_projectile_types: Dictionary[int, StringName] = {}
var _known_data_projectile_owner_peer_ids: Dictionary[int, int] = {}
var _known_data_projectile_damages: Dictionary[int, int] = {}
var _known_data_projectile_lifetimes: Dictionary[int, float] = {}
var _known_fire_sorcerer_volley_services: Dictionary[int, FireSorcererVolleySimulationService] = {}
var _known_fire_sorcerer_volley_handles: Dictionary[int, int] = {}
var _known_fire_sorcerer_volley_metadata: Dictionary[int, Dictionary] = {}
var _known_replica_fire_sorcerer_volley_services: Dictionary[int, FireSorcererVolleySimulationService] = {}
var _known_replica_fire_sorcerer_volley_handles: Dictionary[int, int] = {}
var _reserved_host_projectile_ids: Dictionary[int, int] = {}
var _active_enemy_rapid_fire_bursts: Dictionary[int, Dictionary] = {}
var _active_enemy_rapid_fire_base_by_reserved_id: Dictionary[int, int] = {}
var _pending_enemy_rapid_fire_finish_records: Array[Dictionary] = []
var _enemy_rapid_fire_finish_flush_queued := false
var _known_replica_projectile_services: Dictionary[int, RapidFireSimulationService] = {}
var _known_replica_projectile_handles: Dictionary[int, int] = {}
var _known_replica_projectile_host_timestamps: Dictionary[int, float] = {}
var _seen_enemy_rapid_fire_projectile_expirations: Dictionary[int, float] = {}
var _finished_enemy_rapid_fire_projectile_timestamps: Dictionary[int, float] = {}
var _terminal_enemy_rapid_fire_source_expirations: Dictionary[int, float] = {}
var _terminal_enemy_rapid_fire_source_host_timestamps: Dictionary[int, float] = {}
var _stale_replica_projectile_ids: Array[int] = []
var _stale_enemy_rapid_fire_projectile_ids: Array[int] = []
var _stale_terminal_enemy_rapid_fire_source_ids: Array[int] = []
var _replica_prune_pass_count := 0
var _pending_enemy_rapid_fire_snapshots: Dictionary[int, Dictionary] = {}
var _next_enemy_rapid_fire_snapshot_id := 1
var _latest_applied_enemy_rapid_fire_snapshot_id := 0
var _latest_applied_enemy_rapid_fire_snapshot_host_timestamp := -1.0
var _projectile_records: Dictionary = {}
var _stale_projectile_record_ids: Array[int] = []
var _processed_enemy_hit_ids: Dictionary = {}
var _client_projectile_request_rate_buckets: Dictionary = {}
var _last_tango_volley_visual_state_by_peer: Dictionary = {}


func bind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	assert(runtime_instance != null, "MpProjectileCoordinator 缺少战斗运行时。")
	if _runtime == runtime_instance:
		return
	if _runtime != null:
		reset_session_state()
	_runtime = runtime_instance


func unbind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	if _runtime != runtime_instance:
		return
	reset_session_state()
	_runtime = null
	_clear_network_facade_dependencies()


func is_bound() -> bool:
	return _runtime != null and is_instance_valid(_runtime)


func bind_network_facade_dependencies(
	net_manager_instance: NetManagerStore,
	player_coordinator_instance: MpPlayerCoordinator,
	get_net_time_callable: Callable,
	get_host_event_age_callable: Callable,
	is_embedded_participant_suspended_callable: Callable
) -> void:
	assert(net_manager_instance != null, "MpProjectileCoordinator 缺少 NetManager。")
	assert(
		player_coordinator_instance != null,
		"MpProjectileCoordinator 缺少玩家协调器。"
	)
	assert(
		get_net_time_callable.is_valid(),
		"MpProjectileCoordinator 缺少网络时钟。"
	)
	assert(
		get_host_event_age_callable.is_valid(),
		"MpProjectileCoordinator 缺少 Host 事件时间映射。"
	)
	assert(
		is_embedded_participant_suspended_callable.is_valid(),
		"MpProjectileCoordinator 缺少内嵌参战者状态入口。"
	)
	_net_manager = net_manager_instance
	_player_coordinator = player_coordinator_instance
	_get_net_time_callable = get_net_time_callable
	_get_host_event_age_callable = get_host_event_age_callable
	_is_embedded_participant_suspended_callable = (
		is_embedded_participant_suspended_callable
	)


func has_network_facade_dependencies() -> bool:
	return (
		_net_manager != null
		and _player_coordinator != null
		and _get_net_time_callable.is_valid()
		and _get_host_event_age_callable.is_valid()
		and _is_embedded_participant_suspended_callable.is_valid()
	)


func submit_local_projectile(
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
	if (
		projectile == null
		or not has_network_facade_dependencies()
		or not _net_manager.is_multiplayer_active()
	):
		return
	if not _NetConstants.is_valid_network_combat_value(damage):
		push_error(
			"MpProjectileCoordinator: 投射物伤害超出网络 signed int32 契约，已拒绝发送。"
		)
		return
	var now := _get_net_time()
	var projectile_id := register_local_projectile(
		projectile,
		projectile_type,
		owner_peer_id,
		damage,
		lifetime,
		pierces_enemies,
		_net_manager.is_host(),
		now
	)
	if projectile_id <= 0:
		return
	var host_fire_timestamp := _get_net_time()
	var arguments := [
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
	if _net_manager.is_host():
		rpc_broadcast_requested.emit(&"net_projectile_fired", arguments)
	elif _net_manager.is_client():
		rpc_to_host_requested.emit(
			&"_rpc_projectile_fired_from_client",
			arguments
		)


func register_local_data_projectile(
	service: RapidFireSimulationService,
	handle: int,
	projectile_type: StringName,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	damage_source_snapshot: DamageSourceSnapshot = null
) -> int:
	if (
		service == null
		or not is_instance_valid(service)
		or handle <= RapidFireSimulationService.INVALID_HANDLE
		or projectile_type == &""
		or not has_network_facade_dependencies()
		or not _net_manager.is_multiplayer_active()
		or not _net_manager.is_host()
		or not _NetConstants.is_valid_network_combat_value(damage)
		or not _is_finite_vector2(spawn_position)
		or not _is_finite_vector2(direction)
		or direction.length_squared() <= 0.001
		or not is_finite(speed)
		or speed <= 0.0
		or not is_finite(lifetime)
		or lifetime <= 0.0
		or (
			damage_source_snapshot != null
			and not damage_source_snapshot.is_valid()
		)
		or service.get_slot_mode(handle) != RapidFireSimulationService.Mode.DATA
	):
		return 0
	var projectile_namespace := owner_peer_id
	if projectile_namespace <= 0:
		projectile_namespace = PROJECTILE_ID_FALLBACK_OWNER_PEER_ID
	var projectile_id := allocate_projectile_id(projectile_namespace, true)
	if projectile_id <= 0:
		return 0
	if not service.assign_projectile_identity(handle, projectile_id):
		return 0
	var registered_source_snapshot: DamageSourceSnapshot = null
	if damage_source_snapshot != null:
		registered_source_snapshot = DamageSourceSnapshot.create(
			damage_source_snapshot.source_faction_id,
			damage_source_snapshot.credit_peer_id,
			damage_source_snapshot.instigator_entity_id,
			projectile_id,
			(
				damage_source_snapshot.source_type
				if damage_source_snapshot.source_type != &""
				else projectile_type
			)
		)
	else:
		# The data service owns the authoritative launch-time fallback for its
		# enemy-only profile. Reuse that frozen value so the parallel multiplayer
		# record cannot silently become legacy player-owned when an older caller
		# omits the optional argument.
		registered_source_snapshot = service.get_damage_source_snapshot(handle)
	_known_data_projectile_services[projectile_id] = service
	_known_data_projectile_handles[projectile_id] = handle
	_remember_data_projectile_metadata(
		projectile_id,
		projectile_type,
		owner_peer_id,
		damage,
		lifetime
	)
	remember_projectile_record(
		projectile_id,
		owner_peer_id,
		projectile_type,
		damage,
		lifetime,
		false,
		_get_net_time(),
		registered_source_snapshot
	)
	var host_fire_timestamp := _get_net_time()
	rpc_broadcast_requested.emit(
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
			false,
			0,
			host_fire_timestamp,
			0,
		]
	)
	return projectile_id


func register_local_fire_sorcerer_volley_data(
	service: FireSorcererVolleySimulationService,
	handle: int,
	projectile_type: StringName,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	target_peer_id: int,
	target_enemy_net_id: int,
	damage_source_snapshot: DamageSourceSnapshot
) -> int:
	var profile := _get_fire_sorcerer_volley_profile(projectile_type)
	if (
		service == null
		or not is_instance_valid(service)
		or handle <= FireSorcererVolleySimulationService.INVALID_HANDLE
		or profile == FireSorcererVolleySimulationService.Profile.INVALID
		or not has_network_facade_dependencies()
		or not _net_manager.is_multiplayer_active()
		or not _net_manager.is_host()
		or not _NetConstants.is_valid_network_combat_value(damage)
		or not _is_finite_vector2(spawn_position)
		or not _is_finite_vector2(direction)
		or direction.length_squared() <= 0.001
		or not is_finite(speed)
		or speed <= 0.0
		or not is_finite(lifetime)
		or lifetime <= 0.0
		or target_peer_id < 0
		or target_enemy_net_id < 0
		or damage_source_snapshot == null
		or not damage_source_snapshot.is_valid()
		or damage_source_snapshot.source_faction_id
			!= CombatRelationService.HOSTILE_WAVE
		or service.get_slot_mode(handle)
			!= FireSorcererVolleySimulationService.Mode.DATA
		or service.get_slot_profile(handle) != profile
	):
		return 0
	var projectile_namespace := owner_peer_id
	if projectile_namespace <= 0:
		projectile_namespace = PROJECTILE_ID_FALLBACK_OWNER_PEER_ID
	var projectile_id := allocate_projectile_id(projectile_namespace, true)
	if projectile_id <= 0:
		return 0
	if not service.assign_projectile_identity(handle, projectile_id):
		return 0
	var frozen_source := DamageSourceSnapshot.create(
		damage_source_snapshot.source_faction_id,
		damage_source_snapshot.credit_peer_id,
		damage_source_snapshot.instigator_entity_id,
		projectile_id,
		(
			damage_source_snapshot.source_type
			if damage_source_snapshot.source_type != &""
			else projectile_type
		)
	)
	var host_fire_timestamp := _get_net_time()
	_known_fire_sorcerer_volley_services[projectile_id] = service
	_known_fire_sorcerer_volley_handles[projectile_id] = handle
	_known_fire_sorcerer_volley_metadata[projectile_id] = {
		"projectile_type": projectile_type,
		"owner_peer_id": owner_peer_id,
		"spawn_position": spawn_position,
		"direction": direction.normalized(),
		"damage": damage,
		"speed": speed,
		"lifetime": lifetime,
		"target_peer_id": target_peer_id,
		"target_enemy_net_id": target_enemy_net_id,
		"host_fire_timestamp": host_fire_timestamp,
	}
	remember_projectile_record(
		projectile_id,
		owner_peer_id,
		projectile_type,
		damage,
		lifetime,
		false,
		host_fire_timestamp,
		frozen_source
	)
	rpc_broadcast_requested.emit(
		&"net_projectile_fired",
		[
			projectile_id,
			String(projectile_type),
			owner_peer_id,
			spawn_position,
			direction.normalized(),
			damage,
			speed,
			lifetime,
			false,
			target_peer_id,
			host_fire_timestamp,
			target_enemy_net_id,
		]
	)
	return projectile_id


func notify_fire_sorcerer_volley_finished(
	projectile_id: int,
	service: FireSorcererVolleySimulationService,
	handle: int
) -> void:
	if (
		_known_fire_sorcerer_volley_services.get(projectile_id) == service
		and int(_known_fire_sorcerer_volley_handles.get(
			projectile_id,
			FireSorcererVolleySimulationService.INVALID_HANDLE
		)) == handle
	):
		_erase_fire_sorcerer_volley_backend(projectile_id)
	if (
		_known_replica_fire_sorcerer_volley_services.get(projectile_id) == service
		and int(_known_replica_fire_sorcerer_volley_handles.get(
			projectile_id,
			FireSorcererVolleySimulationService.INVALID_HANDLE
		)) == handle
	):
		_erase_replica_fire_sorcerer_volley_backend(projectile_id)


## Reserves one contiguous Host-origin identity interval without attaching any
## simulation records. A range never wraps and never skips a collision: callers
## either receive the whole interval or an empty result with the sequence cursor
## unchanged.
func reserve_host_projectile_id_range(
	owner_peer_id: int,
	count: int
) -> PackedInt64Array:
	if (
		not has_network_facade_dependencies()
		or not _net_manager.is_multiplayer_active()
		or not _net_manager.is_host()
		or count <= 0
		or count > ENEMY_RAPID_FIRE_MAX_RESERVATION_COUNT
	):
		return PackedInt64Array()
	var projectile_namespace := owner_peer_id
	if projectile_namespace <= 0:
		projectile_namespace = PROJECTILE_ID_FALLBACK_OWNER_PEER_ID
	if projectile_namespace > PROJECTILE_ID_MAX_OWNER_PEER_ID:
		return PackedInt64Array()
	if (
		_next_projectile_sequence <= 0
		or _next_projectile_sequence > PROJECTILE_ID_SEQUENCE_COUNTER_MASK
	):
		_next_projectile_sequence = 1
	var first_sequence := _next_projectile_sequence
	var last_sequence := first_sequence + count - 1
	if last_sequence > PROJECTILE_ID_SEQUENCE_COUNTER_MASK:
		return PackedInt64Array()
	var projectile_ids := PackedInt64Array()
	projectile_ids.resize(count)
	for range_index in range(count):
		var sequence := (first_sequence + range_index) | PROJECTILE_ID_HOST_ORIGIN_BIT
		var projectile_id := encode_projectile_id(projectile_namespace, sequence)
		if (
			projectile_id <= 0
			or _known_projectiles.has(projectile_id)
			or _known_data_projectile_services.has(projectile_id)
			or _known_replica_projectile_services.has(projectile_id)
			or _known_fire_sorcerer_volley_services.has(projectile_id)
			or _known_replica_fire_sorcerer_volley_services.has(projectile_id)
			or _projectile_records.has(projectile_id)
			or _reserved_host_projectile_ids.has(projectile_id)
		):
			return PackedInt64Array()
		projectile_ids[range_index] = projectile_id
	for projectile_id in projectile_ids:
		_reserved_host_projectile_ids[int(projectile_id)] = projectile_namespace
	_next_projectile_sequence = last_sequence + 1
	if _next_projectile_sequence > PROJECTILE_ID_SEQUENCE_COUNTER_MASK:
		_next_projectile_sequence = 1
	return projectile_ids


func release_reserved_host_projectile_ids(
	projectile_ids: PackedInt64Array
) -> bool:
	if (
		projectile_ids.is_empty()
		or not has_network_facade_dependencies()
		or not _net_manager.is_host()
	):
		return false
	var released_any := false
	var discarded_burst_base_ids: Dictionary[int, bool] = {}
	var cancelled_ids_by_burst: Dictionary[int, PackedInt64Array] = {}
	for projectile_id_variant in projectile_ids:
		var projectile_id := int(projectile_id_variant)
		if not _reserved_host_projectile_ids.has(projectile_id):
			continue
		var active_burst_base_id := int(
			_active_enemy_rapid_fire_base_by_reserved_id.get(projectile_id, 0)
		)
		if active_burst_base_id > 0:
			discarded_burst_base_ids[active_burst_base_id] = true
			var cancelled_ids := cancelled_ids_by_burst.get(
				active_burst_base_id,
				PackedInt64Array()
			) as PackedInt64Array
			cancelled_ids.append(projectile_id)
			cancelled_ids_by_burst[active_burst_base_id] = cancelled_ids
		_reserved_host_projectile_ids.erase(projectile_id)
		released_any = true
	for active_burst_base_id in discarded_burst_base_ids.keys():
		_queue_reserved_enemy_rapid_fire_cancellations(
			active_burst_base_id,
			cancelled_ids_by_burst.get(
				active_burst_base_id,
				PackedInt64Array()
			) as PackedInt64Array
		)
		_discard_active_enemy_rapid_fire_burst(active_burst_base_id)
	return released_any


func _queue_reserved_enemy_rapid_fire_cancellations(
	base_projectile_id: int,
	projectile_ids: PackedInt64Array
) -> void:
	var active_burst := _active_enemy_rapid_fire_bursts.get(
		base_projectile_id,
		{}
	) as Dictionary
	if active_burst.is_empty() or projectile_ids.is_empty():
		return
	var decoded := EnemyRapidFireNetworkCodecScript.decode_burst(
		active_burst.get("descriptor", PackedByteArray()) as PackedByteArray
	)
	if not bool(decoded.get("valid", false)):
		return
	var directions := decoded.get(
		"directions",
		PackedVector2Array()
	) as PackedVector2Array
	var origin := decoded.get("origin", Vector2.ZERO) as Vector2
	for projectile_id_variant in projectile_ids:
		var projectile_id := int(projectile_id_variant)
		var projectile_index := projectile_id - base_projectile_id
		if projectile_index < 0 or projectile_index >= directions.size():
			continue
		_pending_enemy_rapid_fire_finish_records.append({
			"projectile_id": projectile_id,
			"reason": ENEMY_RAPID_FIRE_FINISH_REASON_CANCELLED,
			"position": origin,
			"direction": directions[projectile_index],
		})
	_schedule_enemy_rapid_fire_finish_flush()


func _discard_active_enemy_rapid_fire_burst(base_projectile_id: int) -> void:
	_active_enemy_rapid_fire_bursts.erase(base_projectile_id)
	for reserved_projectile_id_variant in (
		_active_enemy_rapid_fire_base_by_reserved_id.keys()
	):
		var reserved_projectile_id := int(reserved_projectile_id_variant)
		if int(_active_enemy_rapid_fire_base_by_reserved_id.get(
			reserved_projectile_id,
			0
		)) == base_projectile_id:
			_active_enemy_rapid_fire_base_by_reserved_id.erase(
				reserved_projectile_id
			)


## Attaches a previously reserved identity to an inert authoritative DATA row.
## This operation deliberately performs no RPC emission; one encoded burst owns
## the corresponding wire event for the entire range.
func attach_reserved_local_data_projectile(
	service: RapidFireSimulationService,
	handle: int,
	projectile_id: int,
	projectile_type: StringName,
	owner_peer_id: int,
	damage: int,
	lifetime: float,
	damage_source_snapshot: DamageSourceSnapshot = null
) -> bool:
	var projectile_namespace := owner_peer_id
	if projectile_namespace <= 0:
		projectile_namespace = PROJECTILE_ID_FALLBACK_OWNER_PEER_ID
	if (
		service == null
		or not is_instance_valid(service)
		or handle <= RapidFireSimulationService.INVALID_HANDLE
		or projectile_id <= 0
		or projectile_type == &""
		or not has_network_facade_dependencies()
		or not _net_manager.is_multiplayer_active()
		or not _net_manager.is_host()
		or not _NetConstants.is_valid_network_combat_value(damage)
		or not is_finite(lifetime)
		or lifetime <= 0.0
		or (
			damage_source_snapshot != null
			and not damage_source_snapshot.is_valid()
		)
		or service.get_slot_mode(handle) != RapidFireSimulationService.Mode.DATA
		or int(_reserved_host_projectile_ids.get(projectile_id, 0))
			!= projectile_namespace
		or not is_projectile_id_valid_for_host_owner(
			projectile_id,
			projectile_namespace
		)
		or _known_projectiles.has(projectile_id)
		or _known_data_projectile_services.has(projectile_id)
		or _known_replica_projectile_services.has(projectile_id)
		or _known_fire_sorcerer_volley_services.has(projectile_id)
		or _known_replica_fire_sorcerer_volley_services.has(projectile_id)
		or _projectile_records.has(projectile_id)
	):
		return false
	if not service.assign_projectile_identity(handle, projectile_id):
		return false
	var registered_source_snapshot: DamageSourceSnapshot = null
	if damage_source_snapshot != null:
		registered_source_snapshot = DamageSourceSnapshot.create(
			damage_source_snapshot.source_faction_id,
			damage_source_snapshot.credit_peer_id,
			damage_source_snapshot.instigator_entity_id,
			projectile_id,
			(
				damage_source_snapshot.source_type
				if damage_source_snapshot.source_type != &""
				else projectile_type
			)
		)
	else:
		registered_source_snapshot = service.get_damage_source_snapshot(handle)
	var active_burst_base_id := int(
		_active_enemy_rapid_fire_base_by_reserved_id.get(projectile_id, 0)
	)
	_reserved_host_projectile_ids.erase(projectile_id)
	_active_enemy_rapid_fire_base_by_reserved_id.erase(projectile_id)
	_known_data_projectile_services[projectile_id] = service
	_known_data_projectile_handles[projectile_id] = handle
	_remember_data_projectile_metadata(
		projectile_id,
		projectile_type,
		owner_peer_id,
		damage,
		lifetime
	)
	remember_projectile_record(
		projectile_id,
		owner_peer_id,
		projectile_type,
		damage,
		lifetime,
		false,
		_get_net_time(),
		registered_source_snapshot
	)
	if active_burst_base_id > 0:
		var active_burst := _active_enemy_rapid_fire_bursts.get(
			active_burst_base_id,
			{}
		) as Dictionary
		if not active_burst.is_empty():
			var remaining_reserved_count := maxi(
				int(active_burst.get("remaining_reserved_count", 0)) - 1,
				0
			)
			if remaining_reserved_count <= 0:
				_active_enemy_rapid_fire_bursts.erase(active_burst_base_id)
			else:
				active_burst["remaining_reserved_count"] = remaining_reserved_count
				_active_enemy_rapid_fire_bursts[active_burst_base_id] = active_burst
	return true


func broadcast_enemy_rapid_fire_burst(
	host_first_shot_timestamp: float,
	descriptor: PackedByteArray
) -> bool:
	if (
		not has_network_facade_dependencies()
		or not _net_manager.is_multiplayer_active()
		or not _net_manager.is_host()
		or not is_finite(host_first_shot_timestamp)
		or host_first_shot_timestamp < 0.0
		or descriptor.is_empty()
		or descriptor.size() > ENEMY_RAPID_FIRE_BURST_MAX_DESCRIPTOR_BYTES
	):
		return false
	var decoded := EnemyRapidFireNetworkCodecScript.decode_burst(descriptor)
	if not _is_attached_enemy_rapid_fire_burst(decoded):
		return false
	var base_projectile_id := int(decoded.get("base_projectile_id", 0))
	var projectile_count := int(decoded.get("count", 0))
	var remaining_reserved_count := 0
	for projectile_index in range(projectile_count):
		var projectile_id := base_projectile_id + projectile_index
		if not _reserved_host_projectile_ids.has(projectile_id):
			continue
		_active_enemy_rapid_fire_base_by_reserved_id[projectile_id] = (
			base_projectile_id
		)
		remaining_reserved_count += 1
	if remaining_reserved_count > 0:
		_active_enemy_rapid_fire_bursts[base_projectile_id] = {
			"host_first_shot_timestamp": host_first_shot_timestamp,
			"descriptor": descriptor,
			"remaining_reserved_count": remaining_reserved_count,
		}
	rpc_broadcast_requested.emit(
		&"net_enemy_rapid_fire_burst",
		[host_first_shot_timestamp, descriptor]
	)
	return true


func _is_attached_enemy_rapid_fire_burst(decoded: Dictionary) -> bool:
	if not bool(decoded.get("valid", false)):
		return false
	var count := int(decoded.get("count", 0))
	var base_projectile_id := int(decoded.get("base_projectile_id", 0))
	var profile := int(decoded.get("profile", 0))
	var source_enemy_id := int(decoded.get("source_enemy_id", 0))
	var speed := float(decoded.get("speed", 0.0))
	var lifetime := float(decoded.get("lifetime", 0.0))
	if (
		not _is_supported_enemy_rapid_fire_profile(profile)
		or not _is_valid_enemy_rapid_fire_projectile_range(
			base_projectile_id,
			count
		)
	):
		return false
	var saw_reserved_suffix := false
	for projectile_index in range(count):
		var projectile_id := base_projectile_id + projectile_index
		if not _known_data_projectile_services.has(projectile_id):
			if (
				int(_reserved_host_projectile_ids.get(projectile_id, 0))
				!= PROJECTILE_ID_FALLBACK_OWNER_PEER_ID
			):
				return false
			saw_reserved_suffix = true
			continue
		if saw_reserved_suffix:
			return false
		var service: RapidFireSimulationService = (
			_known_data_projectile_services.get(projectile_id)
		)
		var handle := int(_known_data_projectile_handles.get(
			projectile_id,
			RapidFireSimulationService.INVALID_HANDLE
		))
		if (
			service == null
			or not is_instance_valid(service)
			or not service.is_handle_live(handle)
			or service.get_slot_mode(handle) != RapidFireSimulationService.Mode.DATA
			or service.get_slot_profile(handle) != profile
			or service.get_source_enemy_id(handle) != source_enemy_id
			or not is_equal_approx(service.get_speed(handle), speed)
			or not is_equal_approx(
				float(_known_data_projectile_lifetimes.get(projectile_id, 0.0)),
				lifetime
			)
		):
			return false
	return not saw_reserved_suffix or _known_data_projectile_services.has(
		base_projectile_id
	)


func send_active_data_visual_snapshot_to_peer(peer_id: int) -> bool:
	if (
		peer_id <= 0
		or not has_network_facade_dependencies()
		or not _net_manager.is_multiplayer_active()
		or not _net_manager.is_host()
	):
		return false
	var active_burst_base_ids: Array[int] = []
	var repair_host_timestamps := PackedFloat64Array()
	var repair_descriptors: Array[PackedByteArray] = []
	for base_projectile_id_variant in _active_enemy_rapid_fire_bursts.keys():
		active_burst_base_ids.append(int(base_projectile_id_variant))
	active_burst_base_ids.sort()
	for base_projectile_id in active_burst_base_ids:
		var active_burst := _active_enemy_rapid_fire_bursts.get(
			base_projectile_id,
			{}
		) as Dictionary
		var descriptor := active_burst.get(
			"descriptor",
			PackedByteArray()
		) as PackedByteArray
		var host_first_shot_timestamp := float(active_burst.get(
			"host_first_shot_timestamp",
			-1.0
		))
		if (
			descriptor.is_empty()
			or descriptor.size() > ENEMY_RAPID_FIRE_BURST_MAX_DESCRIPTOR_BYTES
			or not is_finite(host_first_shot_timestamp)
			or host_first_shot_timestamp < 0.0
		):
			return false
		repair_host_timestamps.append(host_first_shot_timestamp)
		repair_descriptors.append(descriptor)
	var snapshot_id := _next_enemy_rapid_fire_snapshot_id
	_next_enemy_rapid_fire_snapshot_id += 1
	if _next_enemy_rapid_fire_snapshot_id <= 0:
		_next_enemy_rapid_fire_snapshot_id = 1
	var host_snapshot_timestamp := _get_net_time()
	var sorted_projectile_ids: Array[int] = []
	for projectile_id_variant in _known_data_projectile_services.keys():
		sorted_projectile_ids.append(int(projectile_id_variant))
	sorted_projectile_ids.sort()
	var records: Array[Dictionary] = []
	for projectile_id in sorted_projectile_ids:
		var service: RapidFireSimulationService = (
			_known_data_projectile_services.get(projectile_id)
		)
		var handle := int(_known_data_projectile_handles.get(
			projectile_id,
			RapidFireSimulationService.INVALID_HANDLE
		))
		if (
			service == null
			or not is_instance_valid(service)
			or not service.is_handle_live(handle)
			or service.get_slot_mode(handle) != RapidFireSimulationService.Mode.DATA
		):
			_erase_data_projectile_backend(projectile_id)
			continue
		var remaining_lifetime := service.get_remaining_lifetime(handle)
		if remaining_lifetime <= 0.0:
			continue
		records.append({
			"projectile_id": projectile_id,
			"profile": int(service.get_slot_profile(handle)),
			"source_enemy_id": service.get_source_enemy_id(handle),
			"position": service.get_position(handle),
			"direction": service.get_direction(handle),
			"speed": service.get_speed(handle),
			"remaining_lifetime": remaining_lifetime,
		})
	if records.is_empty():
		for repair_index in range(repair_descriptors.size()):
			rpc_to_peer_requested.emit(
				peer_id,
				&"net_enemy_rapid_fire_repair_burst",
				[
					repair_host_timestamps[repair_index],
					repair_descriptors[repair_index],
				]
			)
		rpc_to_peer_requested.emit(
			peer_id,
			&"net_enemy_rapid_fire_snapshot_chunk",
			[
				snapshot_id,
				0,
				0,
				host_snapshot_timestamp,
				PackedByteArray(),
			]
		)
		return _send_active_fire_sorcerer_volleys_to_peer(peer_id)
	var descriptors: Array[PackedByteArray] = []
	for chunk_start in range(
		0,
		records.size(),
		ENEMY_RAPID_FIRE_SNAPSHOT_MAX_PROJECTILES_PER_CHUNK
	):
		var chunk_end := mini(
			chunk_start + ENEMY_RAPID_FIRE_SNAPSHOT_MAX_PROJECTILES_PER_CHUNK,
			records.size()
		)
		var descriptor := EnemyRapidFireNetworkCodecScript.encode_snapshot_chunk(
			records.slice(chunk_start, chunk_end)
		)
		if (
			descriptor.is_empty()
			or descriptor.size() > ENEMY_RAPID_FIRE_SNAPSHOT_MAX_DESCRIPTOR_BYTES
		):
			return false
		descriptors.append(descriptor)
	if descriptors.size() > ENEMY_RAPID_FIRE_MAX_SNAPSHOT_CHUNKS:
		return false
	# Validate and encode the complete repair before emitting any RPC. A failed
	# retry must not expose a burst-only partial manifest to the joining peer.
	for repair_index in range(repair_descriptors.size()):
		rpc_to_peer_requested.emit(
			peer_id,
			&"net_enemy_rapid_fire_repair_burst",
			[
				repair_host_timestamps[repair_index],
				repair_descriptors[repair_index],
			]
		)
	for chunk_index in range(descriptors.size()):
		rpc_to_peer_requested.emit(
			peer_id,
			&"net_enemy_rapid_fire_snapshot_chunk",
			[
				snapshot_id,
				chunk_index,
				descriptors.size(),
				host_snapshot_timestamp,
				descriptors[chunk_index],
			]
		)
	return _send_active_fire_sorcerer_volleys_to_peer(peer_id)


func _send_active_fire_sorcerer_volleys_to_peer(peer_id: int) -> bool:
	var projectile_ids: Array[int] = []
	for projectile_id_variant in _known_fire_sorcerer_volley_services.keys():
		projectile_ids.append(int(projectile_id_variant))
	projectile_ids.sort()
	for projectile_id in projectile_ids:
		if not has_fire_sorcerer_volley_data(projectile_id):
			continue
		var metadata := _known_fire_sorcerer_volley_metadata.get(
			projectile_id,
			{}
		) as Dictionary
		if metadata.is_empty():
			_erase_fire_sorcerer_volley_backend(projectile_id)
			continue
		rpc_to_peer_requested.emit(
			peer_id,
			&"net_projectile_fired",
			[
				projectile_id,
				String(metadata["projectile_type"]),
				int(metadata["owner_peer_id"]),
				metadata["spawn_position"] as Vector2,
				metadata["direction"] as Vector2,
				int(metadata["damage"]),
				float(metadata["speed"]),
				float(metadata["lifetime"]),
				false,
				int(metadata["target_peer_id"]),
				float(metadata["host_fire_timestamp"]),
				int(metadata["target_enemy_net_id"]),
			]
		)
	return true


func notify_data_projectile_finished(
	projectile_id: int,
	service: RapidFireSimulationService,
	handle: int,
	completion_reason: int = RapidFireSimulationService.CompletionReason.NONE,
	completion_position: Vector2 = Vector2.ZERO,
	completion_direction: Vector2 = Vector2.RIGHT
) -> void:
	if (
		_known_data_projectile_services.get(projectile_id) == service
		and int(_known_data_projectile_handles.get(
			projectile_id,
			RapidFireSimulationService.INVALID_HANDLE
		)) == handle
	):
		if (
			has_network_facade_dependencies()
			and _net_manager.is_multiplayer_active()
			and _net_manager.is_host()
			and completion_reason
				> RapidFireSimulationService.CompletionReason.NONE
			and completion_reason
				<= RapidFireSimulationService.CompletionReason.TARGET
			and completion_position.is_finite()
			and completion_direction.is_finite()
			and not completion_direction.is_zero_approx()
		):
			_pending_enemy_rapid_fire_finish_records.append({
				"projectile_id": projectile_id,
				"reason": completion_reason,
				"position": completion_position,
				"direction": completion_direction.normalized(),
			})
		_erase_data_projectile_backend(projectile_id)


func _schedule_enemy_rapid_fire_finish_flush() -> void:
	if _enemy_rapid_fire_finish_flush_queued:
		return
	_enemy_rapid_fire_finish_flush_queued = true
	if is_inside_tree():
		call_deferred(&"_flush_deferred_enemy_rapid_fire_finishes")


func _flush_deferred_enemy_rapid_fire_finishes() -> void:
	flush_enemy_rapid_fire_finish_batch()


func flush_enemy_rapid_fire_finish_batch() -> bool:
	_enemy_rapid_fire_finish_flush_queued = false
	if _pending_enemy_rapid_fire_finish_records.is_empty():
		return true
	if (
		not has_network_facade_dependencies()
		or not _net_manager.is_multiplayer_active()
		or not _net_manager.is_host()
	):
		_pending_enemy_rapid_fire_finish_records.clear()
		return false
	var host_finish_timestamp := _get_net_time()
	var record_start := 0
	while record_start < _pending_enemy_rapid_fire_finish_records.size():
		var record_end := mini(
			record_start + EnemyRapidFireNetworkCodecScript.MAX_FINISH_RECORDS,
			_pending_enemy_rapid_fire_finish_records.size()
		)
		var descriptor := EnemyRapidFireNetworkCodecScript.encode_finish_batch(
			_pending_enemy_rapid_fire_finish_records.slice(
				record_start,
				record_end
			)
		)
		if (
			descriptor.is_empty()
			or descriptor.size() > ENEMY_RAPID_FIRE_FINISH_MAX_DESCRIPTOR_BYTES
		):
			return false
		rpc_broadcast_requested.emit(
			&"net_enemy_rapid_fire_finished_batch",
			[host_finish_timestamp, descriptor]
		)
		record_start = record_end
	_pending_enemy_rapid_fire_finish_records.clear()
	return true


func _erase_data_projectile_backend(projectile_id: int) -> void:
	_known_data_projectile_services.erase(projectile_id)
	_known_data_projectile_handles.erase(projectile_id)
	_known_data_projectile_types.erase(projectile_id)
	_known_data_projectile_owner_peer_ids.erase(projectile_id)
	_known_data_projectile_damages.erase(projectile_id)
	_known_data_projectile_lifetimes.erase(projectile_id)


func _erase_fire_sorcerer_volley_backend(projectile_id: int) -> void:
	_known_fire_sorcerer_volley_services.erase(projectile_id)
	_known_fire_sorcerer_volley_handles.erase(projectile_id)
	_known_fire_sorcerer_volley_metadata.erase(projectile_id)


func _erase_replica_fire_sorcerer_volley_backend(projectile_id: int) -> void:
	_known_replica_fire_sorcerer_volley_services.erase(projectile_id)
	_known_replica_fire_sorcerer_volley_handles.erase(projectile_id)


func _release_and_erase_fire_sorcerer_volley_backend(projectile_id: int) -> void:
	var service: FireSorcererVolleySimulationService = (
		_known_fire_sorcerer_volley_services.get(projectile_id)
	)
	var handle := int(_known_fire_sorcerer_volley_handles.get(
		projectile_id,
		FireSorcererVolleySimulationService.INVALID_HANDLE
	))
	if (
		service != null
		and is_instance_valid(service)
		and handle > FireSorcererVolleySimulationService.INVALID_HANDLE
		and service.is_handle_live(handle)
	):
		service.release_volley(handle)
	_erase_fire_sorcerer_volley_backend(projectile_id)


func _release_and_erase_replica_fire_sorcerer_volley_backend(
	projectile_id: int
) -> void:
	var service: FireSorcererVolleySimulationService = (
		_known_replica_fire_sorcerer_volley_services.get(projectile_id)
	)
	var handle := int(_known_replica_fire_sorcerer_volley_handles.get(
		projectile_id,
		FireSorcererVolleySimulationService.INVALID_HANDLE
	))
	if (
		service != null
		and is_instance_valid(service)
		and handle > FireSorcererVolleySimulationService.INVALID_HANDLE
		and service.is_handle_live(handle)
	):
		service.release_volley(handle)
	_erase_replica_fire_sorcerer_volley_backend(projectile_id)


func _remember_data_projectile_metadata(
	projectile_id: int,
	projectile_type: StringName,
	owner_peer_id: int,
	damage: int,
	lifetime: float
) -> void:
	_known_data_projectile_types[projectile_id] = projectile_type
	_known_data_projectile_owner_peer_ids[projectile_id] = owner_peer_id
	_known_data_projectile_damages[projectile_id] = damage
	_known_data_projectile_lifetimes[projectile_id] = lifetime


func _remember_replica_projectile_backend(
	projectile_id: int,
	service: RapidFireSimulationService,
	handle: int,
	host_timestamp: float,
	live_until: float
) -> void:
	_known_replica_projectile_services[projectile_id] = service
	_known_replica_projectile_handles[projectile_id] = handle
	_known_replica_projectile_host_timestamps[projectile_id] = host_timestamp
	_seen_enemy_rapid_fire_projectile_expirations[projectile_id] = (
		live_until + ENEMY_RAPID_FIRE_REPLICA_DEDUP_RETENTION_SECONDS
	)


func _erase_replica_projectile_backend(projectile_id: int) -> void:
	_known_replica_projectile_services.erase(projectile_id)
	_known_replica_projectile_handles.erase(projectile_id)
	_known_replica_projectile_host_timestamps.erase(projectile_id)


func _release_and_erase_replica_projectile_backend(projectile_id: int) -> void:
	var service: RapidFireSimulationService = (
		_known_replica_projectile_services.get(projectile_id)
	)
	var handle := int(_known_replica_projectile_handles.get(
		projectile_id,
		RapidFireSimulationService.INVALID_HANDLE
	))
	if (
		service != null
		and is_instance_valid(service)
		and handle > RapidFireSimulationService.INVALID_HANDLE
		and service.is_handle_live(handle)
	):
		service.release_projectile(handle)
	_erase_replica_projectile_backend(projectile_id)


func release_replica_projectiles_for_source(
	source_enemy_id: int,
	host_terminal_timestamp: float = -1.0
) -> int:
	if source_enemy_id <= 0:
		return 0
	var now := _get_net_time()
	var terminal_cutoff := (
		host_terminal_timestamp
		if is_finite(host_terminal_timestamp) and host_terminal_timestamp >= 0.0
		else now
	)
	var previous_cutoff := float(
		_terminal_enemy_rapid_fire_source_host_timestamps.get(
			source_enemy_id,
			INF
		)
	)
	terminal_cutoff = minf(terminal_cutoff, previous_cutoff)
	_terminal_enemy_rapid_fire_source_host_timestamps[source_enemy_id] = (
		terminal_cutoff
	)
	_terminal_enemy_rapid_fire_source_expirations[source_enemy_id] = (
		now + ENEMY_RAPID_FIRE_TERMINAL_SOURCE_RETENTION_SECONDS
	)
	var released_count := 0
	for projectile_id_variant in _known_replica_projectile_services.keys():
		var projectile_id := int(projectile_id_variant)
		var service: RapidFireSimulationService = (
			_known_replica_projectile_services.get(projectile_id)
		)
		var handle := int(_known_replica_projectile_handles.get(
			projectile_id,
			RapidFireSimulationService.INVALID_HANDLE
		))
		if (
			service == null
			or not is_instance_valid(service)
			or handle <= RapidFireSimulationService.INVALID_HANDLE
			or not service.is_handle_live(handle)
		):
			_erase_replica_projectile_backend(projectile_id)
			continue
		if service.get_source_enemy_id(handle) != source_enemy_id:
			continue
		# Preserve every projectile authored no later than the Host terminal
		# timestamp. CH4 burst and CH5 terminal packets may arrive in either order;
		# comparing Host-domain timestamps is the only order-independent boundary.
		if float(_known_replica_projectile_host_timestamps.get(
			projectile_id,
			INF
		)) <= terminal_cutoff:
			continue
		_release_and_erase_replica_projectile_backend(projectile_id)
		released_count += 1
	return released_count


func _is_terminal_enemy_rapid_fire_source(
	source_enemy_id: int,
	now: float
) -> bool:
	var expires_at := float(_terminal_enemy_rapid_fire_source_expirations.get(
		source_enemy_id,
		0.0
	))
	if expires_at <= now:
		_terminal_enemy_rapid_fire_source_expirations.erase(source_enemy_id)
		_terminal_enemy_rapid_fire_source_host_timestamps.erase(source_enemy_id)
		return false
	return true


func _get_terminal_enemy_rapid_fire_host_timestamp(
	source_enemy_id: int,
	now: float
) -> float:
	if not _is_terminal_enemy_rapid_fire_source(source_enemy_id, now):
		return -1.0
	return float(_terminal_enemy_rapid_fire_source_host_timestamps.get(
		source_enemy_id,
		-1.0
	))


func _prune_replica_projectile_backends(now: float) -> void:
	# This is a full maintenance sweep and must only run from the existing bounded
	# periodic prune tick. Burst/finish/snapshot packet handlers validate touched
	# IDs lazily; invoking this per packet turns 300 synchronized attackers into
	# an accidental O(packet_count * retained_projectile_count) workload.
	_replica_prune_pass_count += 1
	_stale_replica_projectile_ids.clear()
	for projectile_id_variant in _known_replica_projectile_services:
		var projectile_id := int(projectile_id_variant)
		var service: RapidFireSimulationService = (
			_known_replica_projectile_services.get(projectile_id)
		)
		var handle := int(_known_replica_projectile_handles.get(
			projectile_id,
			RapidFireSimulationService.INVALID_HANDLE
		))
		if (
			service == null
			or not is_instance_valid(service)
			or not service.is_handle_live(handle)
		):
			_stale_replica_projectile_ids.append(projectile_id)
	for projectile_id in _stale_replica_projectile_ids:
		_erase_replica_projectile_backend(projectile_id)
	_stale_enemy_rapid_fire_projectile_ids.clear()
	for projectile_id_variant in _seen_enemy_rapid_fire_projectile_expirations:
		var projectile_id := int(projectile_id_variant)
		if (
			float(_seen_enemy_rapid_fire_projectile_expirations[projectile_id])
			<= now
			and not _known_replica_projectile_services.has(projectile_id)
		):
			_stale_enemy_rapid_fire_projectile_ids.append(projectile_id)
	for projectile_id in _stale_enemy_rapid_fire_projectile_ids:
		_seen_enemy_rapid_fire_projectile_expirations.erase(projectile_id)
		_finished_enemy_rapid_fire_projectile_timestamps.erase(projectile_id)
	_stale_terminal_enemy_rapid_fire_source_ids.clear()
	for source_enemy_id_variant in _terminal_enemy_rapid_fire_source_expirations:
		var source_enemy_id := int(source_enemy_id_variant)
		if (
			float(_terminal_enemy_rapid_fire_source_expirations[source_enemy_id])
			<= now
		):
			_stale_terminal_enemy_rapid_fire_source_ids.append(source_enemy_id)
	for source_enemy_id in _stale_terminal_enemy_rapid_fire_source_ids:
		_terminal_enemy_rapid_fire_source_expirations.erase(source_enemy_id)
		_terminal_enemy_rapid_fire_source_host_timestamps.erase(source_enemy_id)


func _get_rapid_fire_simulation_service() -> RapidFireSimulationService:
	if not is_bound():
		return null
	var combat_services := _runtime.get_enemy_combat_services()
	if combat_services == null:
		return null
	return combat_services.get_rapid_fire_simulation_service()


func _get_fire_sorcerer_volley_simulation_service() -> FireSorcererVolleySimulationService:
	if not is_bound():
		return null
	var combat_services := _runtime.get_enemy_combat_services()
	if combat_services == null:
		return null
	return combat_services.get_fire_sorcerer_volley_simulation_service()


static func _get_fire_sorcerer_volley_profile(
	projectile_type: StringName
) -> FireSorcererVolleySimulationService.Profile:
	match projectile_type:
		FIRE_SORCERER_FIREBALL_VOLLEY_TYPE:
			return FireSorcererVolleySimulationService.Profile.NORMAL
		FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_TYPE:
			return FireSorcererVolleySimulationService.Profile.ELITE
		_:
			return FireSorcererVolleySimulationService.Profile.INVALID


static func _get_fire_sorcerer_volley_burn_level(
	profile: FireSorcererVolleySimulationService.Profile
) -> int:
	return (
		FIRE_SORCERER_ELITE_BURN_LEVEL
		if profile == FireSorcererVolleySimulationService.Profile.ELITE
		else FIRE_SORCERER_NORMAL_BURN_LEVEL
	)


static func _is_supported_enemy_rapid_fire_profile(profile: int) -> bool:
	return (
		profile == RapidFireSimulationService.Profile.AK
		or profile == RapidFireSimulationService.Profile.GUNNER
		or profile == RapidFireSimulationService.Profile.GUNNER_ELITE
	)


static func _is_valid_enemy_rapid_fire_projectile_range(
	base_projectile_id: int,
	count: int
) -> bool:
	if count <= 0:
		return false
	var expected_owner := PROJECTILE_ID_FALLBACK_OWNER_PEER_ID
	for projectile_index in range(count):
		var projectile_id := base_projectile_id + projectile_index
		if not is_projectile_id_valid_for_host_owner(
			projectile_id,
			expected_owner
		):
			return false
		if (
			decode_projectile_sequence_counter(projectile_id)
			!= decode_projectile_sequence_counter(base_projectile_id) + projectile_index
		):
			return false
	return true


func _release_and_erase_data_projectile_backend(projectile_id: int) -> void:
	var service: RapidFireSimulationService = (
		_known_data_projectile_services.get(projectile_id)
	)
	var handle := int(_known_data_projectile_handles.get(
		projectile_id,
		RapidFireSimulationService.INVALID_HANDLE
	))
	if (
		service != null
		and is_instance_valid(service)
		and handle > RapidFireSimulationService.INVALID_HANDLE
		and service.is_handle_live(handle)
	):
		service.release_projectile(handle)
	_erase_data_projectile_backend(projectile_id)


func submit_local_tango_laser_volley(
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
	if (
		not has_network_facade_dependencies()
		or not _net_manager.is_multiplayer_active()
		or not _net_manager.is_host()
	):
		return false
	var charge_sequence := _player_coordinator.get_tango_charge_sequence(
		owner_peer_id
	)
	var maximum_internal_barrage_seconds := (
		_player_coordinator.get_tango_laser_barrage_maximum_seconds(
			owner_peer_id,
			charge_ratio
		)
	)
	var projectile_ids := register_local_tango_laser_volley(
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
	if projectile_ids.is_empty():
		return false
	var host_fire_timestamp := _get_net_time()
	rpc_broadcast_requested.emit(
		&"net_tango_laser_volley",
		[
			projectile_ids,
			spawn_positions,
			direction.normalized(),
			owner_peer_id,
			charge_sequence,
			charge_ratio,
			minf(
				barrage_remaining_seconds,
				TANGO_NETWORK_BARRAGE_MAXIMUM_SECONDS
			),
			damage,
			speed,
			lifetime,
			host_fire_timestamp,
		]
	)
	return true


func submit_local_linglan_skill1_ring(
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
		or not has_network_facade_dependencies()
		or not _net_manager.is_multiplayer_active()
		or not _net_manager.is_host()
	):
		return
	var projectile_ids := register_local_linglan_skill1_ring(
		projectiles,
		owner_peer_id,
		damage,
		lifetime,
		_get_net_time()
	)
	if projectile_ids.size() != projectile_count:
		return
	var host_fire_timestamp := _get_net_time()
	for chunk_start in range(
		0,
		projectile_ids.size(),
		LINGLAN_SKILL1_RING_MAX_PROJECTILES_PER_PACKET
	):
		var chunk_end := mini(
			chunk_start + LINGLAN_SKILL1_RING_MAX_PROJECTILES_PER_PACKET,
			projectile_ids.size()
		)
		rpc_broadcast_requested.emit(
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


func handle_client_projectile_fired(
	sender_id: int,
	projectile_id: int,
	projectile_type_text: String,
	owner_peer_id: int,
	reported_spawn_position: Vector2,
	reported_direction: Vector2,
	reported_damage: int,
	_reported_speed: float,
	_reported_lifetime: float,
	_reported_pierces_enemies: bool = false,
	target_peer_id: int = 0,
	_client_fire_timestamp: float = -1.0,
	_target_enemy_net_id: int = 0
) -> void:
	if (
		not has_network_facade_dependencies()
		or not _net_manager.is_host()
		or not _NetConstants.is_valid_network_combat_value(reported_damage)
	):
		return
	var now := _get_net_time()
	if not accept_client_projectile_request_identity(
		sender_id,
		projectile_id,
		owner_peer_id,
		bool(_is_embedded_participant_suspended_callable.call(sender_id)),
		now
	):
		return
	var accepted_direction := get_valid_client_projectile_direction(
		reported_direction
	)
	if accepted_direction == Vector2.ZERO:
		return
	var projectile_type := StringName(projectile_type_text)
	if (
		projectile_type != TIYI_SNIPER_PROJECTILE_TYPE
		and not is_client_projectile_spawn_position_allowed(
			projectile_type,
			owner_peer_id,
			reported_spawn_position,
			_player_coordinator.get_accepted_player_position(owner_peer_id),
			CLIENT_PROJECTILE_SPAWN_POSITION_TOLERANCE
		)
	):
		return
	var accepted_parameters := get_authoritative_client_projectile_parameters(
		projectile_type,
		owner_peer_id
	)
	if accepted_parameters.is_empty():
		return
	var accepted_spawn_position := (
		get_authoritative_client_projectile_spawn_position(
			projectile_type,
			owner_peer_id,
			reported_spawn_position,
			accepted_direction
		)
	)
	if not _is_finite_vector2(accepted_spawn_position):
		return
	var accepted_damage := int(accepted_parameters["damage"])
	if not _NetConstants.is_valid_network_combat_value(accepted_damage):
		push_error(
			"MpProjectileCoordinator: 权威投射物伤害超出网络 signed int32 契约，已拒绝发送。"
		)
		return
	var accepted_speed := float(accepted_parameters["speed"])
	var accepted_lifetime := float(accepted_parameters["lifetime"])
	var accepted_pierces_enemies := bool(
		accepted_parameters.get("pierces_enemies", false)
	)
	var accepted_target_enemy_net_id := resolve_authoritative_homing_target(
		owner_peer_id,
		accepted_direction,
		bool(accepted_parameters.get("homes_to_enemy", false))
	)
	var host_fire_timestamp := _get_net_time()
	var accepted_arguments := [
		projectile_id,
		projectile_type_text,
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
	rpc_broadcast_requested.emit(&"net_projectile_fired", accepted_arguments)
	receive_projectile_fired(
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
		accepted_target_enemy_net_id,
		0.0,
		host_fire_timestamp
	)


func apply_authority_projectile_fired(
	sender_id: int,
	projectile_id: int,
	projectile_type_text: String,
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
	if not _is_authority_sender(sender_id):
		return
	var projectile_type := StringName(projectile_type_text)
	var event_age := _get_host_event_age(host_fire_timestamp)
	receive_projectile_fired(
		projectile_id,
		projectile_type,
		owner_peer_id,
		spawn_position,
		direction,
		damage,
		speed,
		lifetime,
		pierces_enemies,
		target_peer_id,
		target_enemy_net_id,
		get_projectile_time_compensation_age(
			event_age,
			lifetime,
			projectile_type
		),
		_get_net_time()
	)


func apply_authority_enemy_rapid_fire_burst(
	sender_id: int,
	host_first_shot_timestamp: float,
	descriptor: PackedByteArray
) -> bool:
	if (
		not _is_authority_sender(sender_id)
		or not is_finite(host_first_shot_timestamp)
		or host_first_shot_timestamp < 0.0
		or descriptor.is_empty()
		or descriptor.size() > ENEMY_RAPID_FIRE_BURST_MAX_DESCRIPTOR_BYTES
	):
		return false
	var decoded := EnemyRapidFireNetworkCodecScript.decode_burst(descriptor)
	if not bool(decoded.get("valid", false)):
		return false
	var projectile_count := int(decoded.get("count", 0))
	var base_projectile_id := int(decoded.get("base_projectile_id", 0))
	var profile := int(decoded.get("profile", 0))
	var source_enemy_id := int(decoded.get("source_enemy_id", 0))
	var source_position := decoded.get("source_position", Vector2.ZERO) as Vector2
	var action_id := int(decoded.get("action_id", 0))
	var origin := decoded.get("origin", Vector2.ZERO) as Vector2
	var locked_direction := decoded.get(
		"locked_direction",
		Vector2.RIGHT
	) as Vector2
	var interval := float(decoded.get("interval", -1.0))
	var speed := float(decoded.get("speed", 0.0))
	var lifetime := float(decoded.get("lifetime", 0.0))
	var directions := decoded.get("directions", PackedVector2Array()) as PackedVector2Array
	if (
		projectile_count <= 0
		or projectile_count > EnemyRapidFireNetworkCodecScript.MAX_BURST_PROJECTILES
		or directions.size() != projectile_count
		or not _is_supported_enemy_rapid_fire_profile(profile)
		or not _is_valid_enemy_rapid_fire_projectile_range(
			base_projectile_id,
			projectile_count
		)
	):
		return false
	var service := _get_rapid_fire_simulation_service()
	if service == null:
		return false
	var now := _get_net_time()
	var terminal_host_timestamp := (
		_get_terminal_enemy_rapid_fire_host_timestamp(source_enemy_id, now)
	)
	var first_shot_event_age := _get_host_event_age(host_first_shot_timestamp)
	var should_present_action := (
		(
			terminal_host_timestamp < 0.0
			or host_first_shot_timestamp <= terminal_host_timestamp
		)
		and
		_latest_applied_enemy_rapid_fire_snapshot_host_timestamp
			< host_first_shot_timestamp
		and not has_replica_projectile(base_projectile_id)
		and float(_seen_enemy_rapid_fire_projectile_expirations.get(
			base_projectile_id,
			0.0
		)) <= now
	)
	for projectile_index in range(projectile_count):
		var projectile_id := base_projectile_id + projectile_index
		var shot_offset := interval * projectile_index
		var projectile_host_timestamp := host_first_shot_timestamp + shot_offset
		if (
			terminal_host_timestamp >= 0.0
			and projectile_host_timestamp > terminal_host_timestamp
		):
			_seen_enemy_rapid_fire_projectile_expirations[projectile_id] = (
				now + ENEMY_RAPID_FIRE_FINISH_DEDUP_RETENTION_SECONDS
			)
			continue
		if (
			_latest_applied_enemy_rapid_fire_snapshot_host_timestamp >= 0.0
			and projectile_host_timestamp
				<= _latest_applied_enemy_rapid_fire_snapshot_host_timestamp
		):
			_seen_enemy_rapid_fire_projectile_expirations[projectile_id] = (
				now + ENEMY_RAPID_FIRE_REPLICA_DEDUP_RETENTION_SECONDS
			)
			continue
		if (
			has_replica_projectile(projectile_id)
			or float(_seen_enemy_rapid_fire_projectile_expirations.get(
				projectile_id,
				0.0
			)) > now
		):
			continue
		var shot_age := first_shot_event_age - shot_offset
		var activation_delay := maxf(-shot_age, 0.0)
		var active_age := maxf(shot_age, 0.0)
		var remaining_lifetime := lifetime - active_age
		if remaining_lifetime <= 0.0:
			_seen_enemy_rapid_fire_projectile_expirations[projectile_id] = (
				now + ENEMY_RAPID_FIRE_REPLICA_DEDUP_RETENTION_SECONDS
			)
			continue
		var direction := directions[projectile_index]
		var compensated_position := origin + direction * speed * active_age
		var handle := service.register_replica_projectile(
			profile as RapidFireSimulationService.Profile,
			compensated_position,
			direction,
			speed,
			remaining_lifetime,
			source_enemy_id,
			projectile_id,
			activation_delay
		)
		if handle <= RapidFireSimulationService.INVALID_HANDLE:
			continue
		_remember_replica_projectile_backend(
			projectile_id,
			service,
			handle,
			projectile_host_timestamp,
			now + activation_delay + remaining_lifetime
		)
	if should_present_action:
		enemy_rapid_fire_action_requested.emit(
			source_enemy_id,
			profile,
			locked_direction,
			source_position,
			action_id,
			host_first_shot_timestamp,
			first_shot_event_age
		)
	return true


func apply_authority_enemy_rapid_fire_finished_batch(
	sender_id: int,
	host_finish_timestamp: float,
	descriptor: PackedByteArray
) -> bool:
	if (
		not _is_authority_sender(sender_id)
		or not is_finite(host_finish_timestamp)
		or host_finish_timestamp < 0.0
		or descriptor.is_empty()
		or descriptor.size() > ENEMY_RAPID_FIRE_FINISH_MAX_DESCRIPTOR_BYTES
	):
		return false
	var decoded := EnemyRapidFireNetworkCodecScript.decode_finish_batch(
		descriptor
	)
	if not bool(decoded.get("valid", false)):
		return false
	var now := _get_net_time()
	var combat_services := (
		_runtime.get_enemy_combat_services()
		if is_bound()
		else null
	)
	var presenter := (
		combat_services.get_rapid_projectile_presenter()
		if combat_services != null
		else null
	)
	for record_variant in decoded.get("records", []) as Array:
		var record := record_variant as Dictionary
		var projectile_id := int(record.get("projectile_id", 0))
		var previous_finish_timestamp := float(
			_finished_enemy_rapid_fire_projectile_timestamps.get(
				projectile_id,
				-1.0
			)
		)
		if host_finish_timestamp < previous_finish_timestamp:
			continue
		_finished_enemy_rapid_fire_projectile_timestamps[projectile_id] = (
			host_finish_timestamp
		)
		_seen_enemy_rapid_fire_projectile_expirations[projectile_id] = (
			now + ENEMY_RAPID_FIRE_FINISH_DEDUP_RETENTION_SECONDS
		)
		if not has_replica_projectile(projectile_id):
			continue
		var service: RapidFireSimulationService = (
			_known_replica_projectile_services.get(projectile_id)
		)
		var handle := int(_known_replica_projectile_handles.get(
			projectile_id,
			RapidFireSimulationService.INVALID_HANDLE
		))
		if service == null or not service.is_handle_live(handle):
			_erase_replica_projectile_backend(projectile_id)
			continue
		var reason := int(record.get(
			"reason",
			RapidFireSimulationService.CompletionReason.NONE
		)) as RapidFireSimulationService.CompletionReason
		if (
			presenter != null
			and (
				reason == RapidFireSimulationService.CompletionReason.WORLD
				or reason == RapidFireSimulationService.CompletionReason.TARGET
			)
		):
			presenter.queue_completion_hit(
				RapidFireSimulationService.Mode.REPLICA,
				service.get_slot_profile(handle),
				reason,
				record.get("position", Vector2.ZERO) as Vector2,
				record.get("direction", Vector2.RIGHT) as Vector2
			)
		_release_and_erase_replica_projectile_backend(projectile_id)
	return true


func apply_authority_enemy_rapid_fire_snapshot_chunk(
	sender_id: int,
	snapshot_id: int,
	chunk_index: int,
	chunk_count: int,
	host_snapshot_timestamp: float,
	descriptor: PackedByteArray
) -> bool:
	if (
		not _is_authority_sender(sender_id)
		or snapshot_id <= 0
		or chunk_count < 0
		or chunk_count > ENEMY_RAPID_FIRE_MAX_SNAPSHOT_CHUNKS
		or not is_finite(host_snapshot_timestamp)
		or host_snapshot_timestamp < 0.0
		or snapshot_id <= _latest_applied_enemy_rapid_fire_snapshot_id
	):
		return snapshot_id <= _latest_applied_enemy_rapid_fire_snapshot_id
	if chunk_count == 0:
		if chunk_index != 0 or not descriptor.is_empty():
			return false
		return _apply_complete_enemy_rapid_fire_snapshot(
			snapshot_id,
			host_snapshot_timestamp,
			[]
		)
	if (
		chunk_index < 0
		or chunk_index >= chunk_count
		or descriptor.is_empty()
		or descriptor.size() > ENEMY_RAPID_FIRE_SNAPSHOT_MAX_DESCRIPTOR_BYTES
	):
		return false
	var decoded := EnemyRapidFireNetworkCodecScript.decode_snapshot_chunk(
		descriptor
	)
	if not bool(decoded.get("valid", false)):
		return false
	var pending: Dictionary
	if _pending_enemy_rapid_fire_snapshots.has(snapshot_id):
		pending = _pending_enemy_rapid_fire_snapshots[snapshot_id] as Dictionary
		if (
			int(pending.get("chunk_count", -1)) != chunk_count
			or not is_equal_approx(
				float(pending.get("host_snapshot_timestamp", -1.0)),
				host_snapshot_timestamp
			)
		):
			return false
	else:
		_trim_pending_enemy_rapid_fire_snapshots()
		pending = {
			"chunk_count": chunk_count,
			"host_snapshot_timestamp": host_snapshot_timestamp,
			"chunks": {},
		}
	var chunks := pending.get("chunks", {}) as Dictionary
	if chunks.has(chunk_index):
		return (chunks[chunk_index] as PackedByteArray) == descriptor
	chunks[chunk_index] = descriptor
	pending["chunks"] = chunks
	_pending_enemy_rapid_fire_snapshots[snapshot_id] = pending
	if chunks.size() < chunk_count:
		return true
	var records: Array[Dictionary] = []
	var seen_projectile_ids: Dictionary[int, bool] = {}
	for ordered_chunk_index in range(chunk_count):
		if not chunks.has(ordered_chunk_index):
			return true
		var ordered_decoded := (
			EnemyRapidFireNetworkCodecScript.decode_snapshot_chunk(
				chunks[ordered_chunk_index] as PackedByteArray
			)
		)
		if not bool(ordered_decoded.get("valid", false)):
			_pending_enemy_rapid_fire_snapshots.erase(snapshot_id)
			return false
		var chunk_records := ordered_decoded.get("records", []) as Array
		for record_variant in chunk_records:
			var record := record_variant as Dictionary
			var projectile_id := int(record.get("projectile_id", 0))
			if seen_projectile_ids.has(projectile_id):
				_pending_enemy_rapid_fire_snapshots.erase(snapshot_id)
				return false
			seen_projectile_ids[projectile_id] = true
			records.append(record)
	return _apply_complete_enemy_rapid_fire_snapshot(
		snapshot_id,
		host_snapshot_timestamp,
		records
	)


func _apply_complete_enemy_rapid_fire_snapshot(
	snapshot_id: int,
	host_snapshot_timestamp: float,
	records: Array[Dictionary]
) -> bool:
	var service := _get_rapid_fire_simulation_service()
	if service == null:
		_pending_enemy_rapid_fire_snapshots.erase(snapshot_id)
		return false
	for record in records:
		var projectile_id := int(record.get("projectile_id", 0))
		var profile := int(record.get("profile", 0))
		if (
			not _is_supported_enemy_rapid_fire_profile(profile)
			or not is_projectile_id_valid_for_host_owner(
				projectile_id,
				PROJECTILE_ID_FALLBACK_OWNER_PEER_ID
			)
		):
			_pending_enemy_rapid_fire_snapshots.erase(snapshot_id)
			return false
	var event_age := _get_host_event_age(host_snapshot_timestamp)
	var now := _get_net_time()
	var prepared_projectile_ids := PackedInt64Array()
	var prepared_records: Array[Dictionary] = []
	var prepared_handles := PackedInt64Array()
	var prepared_remaining_lifetimes := PackedFloat64Array()
	var expired_projectile_ids := PackedInt64Array()
	for record in records:
		var projectile_id := int(record["projectile_id"])
		if float(_finished_enemy_rapid_fire_projectile_timestamps.get(
			projectile_id,
			-1.0
		)) >= host_snapshot_timestamp:
			continue
		if (
			has_replica_projectile(projectile_id)
			and float(_known_replica_projectile_host_timestamps.get(
				projectile_id,
				-INF
			)) > host_snapshot_timestamp
		):
			continue
		# A repair snapshot is a later reliable statement about live Host DATA.
		# It may legitimately contain a projectile fired before its source enemy
		# terminated, so the burst-only terminal fence must not suppress it.
		var remaining_lifetime := (
			float(record["remaining_lifetime"]) - event_age
		)
		if remaining_lifetime <= 0.0:
			expired_projectile_ids.append(projectile_id)
			continue
		prepared_projectile_ids.append(projectile_id)
		prepared_records.append(record)
		prepared_remaining_lifetimes.append(remaining_lifetime)
	# Register the complete replacement set alongside the old rows. Only after
	# every handle exists do we release the previous snapshot and publish maps.
	# This makes capacity/teardown/generation failures retryable and atomic.
	if not service.reserve_projectile_capacity(
		service.get_dense_record_count() + prepared_projectile_ids.size()
	):
		_pending_enemy_rapid_fire_snapshots.erase(snapshot_id)
		return false
	for prepared_index in range(prepared_projectile_ids.size()):
		var projectile_id := int(prepared_projectile_ids[prepared_index])
		var record := prepared_records[prepared_index]
		var direction := record["direction"] as Vector2
		var speed := float(record["speed"])
		var position := (
			record["position"] as Vector2
		) + direction * speed * event_age
		var handle := service.register_replica_projectile(
			int(record["profile"]) as RapidFireSimulationService.Profile,
			position,
			direction,
			speed,
			prepared_remaining_lifetimes[prepared_index],
			int(record["source_enemy_id"]),
			projectile_id,
			0.0
		)
		if handle <= RapidFireSimulationService.INVALID_HANDLE:
			for prepared_handle in prepared_handles:
				service.release_projectile(int(prepared_handle))
			_pending_enemy_rapid_fire_snapshots.erase(snapshot_id)
			return false
		prepared_handles.append(handle)
	for projectile_id_variant in _known_replica_projectile_services.keys():
		var projectile_id := int(projectile_id_variant)
		if (
			float(_known_replica_projectile_host_timestamps.get(
				projectile_id,
				-INF
			)) <= host_snapshot_timestamp
		):
			_release_and_erase_replica_projectile_backend(projectile_id)
	for expired_projectile_id in expired_projectile_ids:
		_seen_enemy_rapid_fire_projectile_expirations[int(expired_projectile_id)] = (
			now + ENEMY_RAPID_FIRE_REPLICA_DEDUP_RETENTION_SECONDS
		)
	for prepared_index in range(prepared_projectile_ids.size()):
		var projectile_id := int(prepared_projectile_ids[prepared_index])
		var remaining_lifetime := prepared_remaining_lifetimes[prepared_index]
		_remember_replica_projectile_backend(
			projectile_id,
			service,
			int(prepared_handles[prepared_index]),
			host_snapshot_timestamp,
			now + remaining_lifetime
		)
	_latest_applied_enemy_rapid_fire_snapshot_id = snapshot_id
	_latest_applied_enemy_rapid_fire_snapshot_host_timestamp = (
		host_snapshot_timestamp
	)
	for pending_snapshot_id_variant in (
		_pending_enemy_rapid_fire_snapshots.keys()
	):
		var pending_snapshot_id := int(pending_snapshot_id_variant)
		if pending_snapshot_id <= snapshot_id:
			_pending_enemy_rapid_fire_snapshots.erase(pending_snapshot_id)
	return true


func _trim_pending_enemy_rapid_fire_snapshots() -> void:
	if (
		_pending_enemy_rapid_fire_snapshots.size()
		< ENEMY_RAPID_FIRE_MAX_PENDING_SNAPSHOTS
	):
		return
	var oldest_snapshot_id := 0
	for snapshot_id_variant in _pending_enemy_rapid_fire_snapshots.keys():
		var snapshot_id := int(snapshot_id_variant)
		if oldest_snapshot_id == 0 or snapshot_id < oldest_snapshot_id:
			oldest_snapshot_id = snapshot_id
	if oldest_snapshot_id > 0:
		_pending_enemy_rapid_fire_snapshots.erase(oldest_snapshot_id)


func apply_authority_tango_laser_volley(
	sender_id: int,
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
	if (
		not _is_authority_sender(sender_id)
		or not is_valid_tango_laser_volley_payload(
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
	):
		return
	var current_charge_sequence := _player_coordinator.get_tango_charge_sequence(
		owner_peer_id
	)
	var previous_visual_state := (
		_last_tango_volley_visual_state_by_peer.get(owner_peer_id, {})
		as Dictionary
	)
	var previous_visual_sequence := int(previous_visual_state.get("sequence", 0))
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
		_player_coordinator.observe_tango_charge_sequence(
			owner_peer_id,
			charge_sequence
		)
	var barrage_age := _get_host_event_age(host_fire_timestamp)
	if should_apply_visual_state:
		_last_tango_volley_visual_state_by_peer[owner_peer_id] = {
			"sequence": charge_sequence,
			"host_fire_timestamp": host_fire_timestamp,
		}
		var owner_player := _get_player(owner_peer_id) as PlayerTango
		if owner_player != null:
			owner_player.apply_remote_tango_barrage_snapshot(
				direction,
				charge_ratio,
				charge_sequence,
				barrage_remaining_seconds - barrage_age
			)
			if barrage_age <= lifetime:
				owner_player.play_remote_tango_volley_audio()
	var next_charge_sequence := receive_tango_laser_volley(
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
		_player_coordinator.observe_tango_charge_sequence(
			owner_peer_id,
			next_charge_sequence
		)


func apply_authority_linglan_skill1_ring(
	sender_id: int,
	projectile_ids: PackedInt64Array,
	spawn_positions: PackedVector2Array,
	directions: PackedVector2Array,
	owner_peer_id: int,
	damage: int,
	speed: float,
	lifetime: float,
	host_fire_timestamp: float
) -> void:
	if not _is_authority_sender(sender_id):
		return
	receive_linglan_skill1_ring(
		projectile_ids,
		spawn_positions,
		directions,
		owner_peer_id,
		damage,
		speed,
		lifetime,
		host_fire_timestamp,
		_get_host_event_age(host_fire_timestamp),
		_get_net_time()
	)


func register_local_projectile(
	projectile: Node,
	projectile_type: StringName,
	owner_peer_id: int,
	damage: int,
	lifetime: float,
	pierces_enemies: bool,
	host_origin: bool,
	now: float
) -> int:
	if (
		projectile == null
		or not is_instance_valid(projectile)
		or not _NetConstants.is_valid_network_combat_value(damage)
	):
		return 0
	if not bind_player_projectile_gameplay_context(projectile):
		return 0
	var projectile_namespace := owner_peer_id
	if projectile_namespace <= 0:
		projectile_namespace = PROJECTILE_ID_FALLBACK_OWNER_PEER_ID
	var projectile_id := allocate_projectile_id(
		projectile_namespace,
		host_origin
	)
	if projectile_id <= 0:
		push_error(
			"MpProjectileCoordinator: unable to allocate projectile id for owner %d."
			% projectile_namespace
		)
		return 0
	setup_projectile_network_identity(
		projectile,
		projectile_id,
		owner_peer_id,
		projectile_type
	)
	_known_projectiles[projectile_id] = projectile
	var source_snapshot_variant: Variant = (
		projectile.get_meta(DAMAGE_SOURCE_SNAPSHOT_META)
		if projectile.has_meta(DAMAGE_SOURCE_SNAPSHOT_META)
		else null
	)
	var source_snapshot := (
		source_snapshot_variant as DamageSourceSnapshot
		if source_snapshot_variant is DamageSourceSnapshot
		else null
	)
	remember_projectile_record(
		projectile_id,
		owner_peer_id,
		projectile_type,
		damage,
		lifetime,
		pierces_enemies,
		now,
		source_snapshot
	)
	return projectile_id


func register_local_tango_laser_volley(
	projectiles: Array[Node],
	spawn_positions: PackedVector2Array,
	direction: Vector2,
	owner_peer_id: int,
	damage: int,
	speed: float,
	lifetime: float,
	charge_sequence: int,
	charge_ratio: float,
	barrage_remaining_seconds: float,
	maximum_barrage_seconds: float,
	now: float
) -> PackedInt64Array:
	if (
		projectiles.size() != TANGO_LASER_VOLLEY_PROJECTILE_COUNT
		or spawn_positions.size() != TANGO_LASER_VOLLEY_PROJECTILE_COUNT
		or charge_sequence <= 0
		or owner_peer_id <= 0
		or owner_peer_id > PROJECTILE_ID_MAX_OWNER_PEER_ID
		or not _NetConstants.is_valid_network_combat_value(damage)
		or not _is_finite_vector2(direction)
		or direction.length_squared() <= 0.001
		or not is_finite(speed)
		or speed <= 0.0
		or not is_finite(lifetime)
		or lifetime <= 0.0
		or not is_finite(charge_ratio)
		or charge_ratio < 0.0
		or charge_ratio > 1.0
		or not is_finite(barrage_remaining_seconds)
		or barrage_remaining_seconds < 0.0
		or barrage_remaining_seconds > maximum_barrage_seconds
	):
		return PackedInt64Array()
	for projectile_index in range(TANGO_LASER_VOLLEY_PROJECTILE_COUNT):
		var projectile := projectiles[projectile_index]
		if (
			projectile == null
			or not is_instance_valid(projectile)
			or not bind_player_projectile_gameplay_context(projectile)
			or not _is_finite_vector2(spawn_positions[projectile_index])
		):
			return PackedInt64Array()

	var projectile_ids := PackedInt64Array()
	for _projectile_index in range(TANGO_LASER_VOLLEY_PROJECTILE_COUNT):
		var projectile_id := allocate_projectile_id(owner_peer_id, true)
		if projectile_id <= 0:
			return PackedInt64Array()
		projectile_ids.append(projectile_id)
	for projectile_index in range(TANGO_LASER_VOLLEY_PROJECTILE_COUNT):
		var projectile := projectiles[projectile_index]
		var projectile_id := int(projectile_ids[projectile_index])
		setup_projectile_network_identity(
			projectile,
			projectile_id,
			owner_peer_id,
			TANGO_LASER_PROJECTILE_TYPE
		)
		_known_projectiles[projectile_id] = projectile
		remember_projectile_record(
			projectile_id,
			owner_peer_id,
			TANGO_LASER_PROJECTILE_TYPE,
			damage,
			lifetime,
			false,
			now
		)
	return projectile_ids


func register_local_linglan_skill1_ring(
	projectiles: Array[Node],
	owner_peer_id: int,
	damage: int,
	lifetime: float,
	now: float
) -> PackedInt64Array:
	if (
		projectiles.is_empty()
		or owner_peer_id <= 0
		or owner_peer_id > PROJECTILE_ID_MAX_OWNER_PEER_ID
		or not _NetConstants.is_valid_network_combat_value(damage)
	):
		return PackedInt64Array()
	for projectile in projectiles:
		if projectile == null or not is_instance_valid(projectile):
			return PackedInt64Array()
	var projectile_ids := PackedInt64Array()
	for projectile in projectiles:
		var projectile_id := register_local_projectile(
			projectile,
			&"linglan_skill1",
			owner_peer_id,
			damage,
			lifetime,
			false,
			true,
			now
		)
		if projectile_id <= 0:
			return PackedInt64Array()
		projectile_ids.append(projectile_id)
	return projectile_ids


func allocate_projectile_id(owner_peer_id: int, host_origin: bool) -> int:
	if owner_peer_id <= 0 or owner_peer_id > PROJECTILE_ID_MAX_OWNER_PEER_ID:
		return 0
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
		var projectile_id := encode_projectile_id(owner_peer_id, sequence)
		if (
			projectile_id > 0
			and not _known_projectiles.has(projectile_id)
			and not _known_data_projectile_services.has(projectile_id)
			and not _known_replica_projectile_services.has(projectile_id)
			and not _known_fire_sorcerer_volley_services.has(projectile_id)
			and not _known_replica_fire_sorcerer_volley_services.has(projectile_id)
			and not _projectile_records.has(projectile_id)
			and not _reserved_host_projectile_ids.has(projectile_id)
		):
			return projectile_id
		if _next_projectile_sequence == first_sequence:
			return 0
	return 0


func accept_client_projectile_request_identity(
	sender_id: int,
	projectile_id: int,
	owner_peer_id: int,
	is_suspended: bool,
	now: float
) -> bool:
	if (
		sender_id <= 0
		or owner_peer_id != sender_id
		or is_suspended
		or _known_projectiles.has(projectile_id)
		or _known_data_projectile_services.has(projectile_id)
		or _known_fire_sorcerer_volley_services.has(projectile_id)
		or _known_replica_fire_sorcerer_volley_services.has(projectile_id)
		or _projectile_records.has(projectile_id)
		or not is_projectile_id_valid_for_client_owner(
			projectile_id,
			owner_peer_id
		)
	):
		return false
	return _consume_peer_rate_token(
		sender_id,
		now,
		CLIENT_PROJECTILE_REQUEST_RATE_PER_SECOND,
		CLIENT_PROJECTILE_REQUEST_RATE_BURST
	)


func has_projectile(projectile_id: int) -> bool:
	return _known_projectiles.has(projectile_id)


func has_data_projectile(projectile_id: int) -> bool:
	var service: RapidFireSimulationService = (
		_known_data_projectile_services.get(projectile_id)
	)
	if (
		service == null
		or not is_instance_valid(service)
		or not _known_data_projectile_handles.has(projectile_id)
	):
		_erase_data_projectile_backend(projectile_id)
		return false
	return true


func has_fire_sorcerer_volley_data(projectile_id: int) -> bool:
	var service: FireSorcererVolleySimulationService = (
		_known_fire_sorcerer_volley_services.get(projectile_id)
	)
	var handle := int(_known_fire_sorcerer_volley_handles.get(
		projectile_id,
		FireSorcererVolleySimulationService.INVALID_HANDLE
	))
	if (
		service == null
		or not is_instance_valid(service)
		or handle <= FireSorcererVolleySimulationService.INVALID_HANDLE
		or not service.is_handle_live(handle)
		or service.get_slot_mode(handle)
			!= FireSorcererVolleySimulationService.Mode.DATA
	):
		_erase_fire_sorcerer_volley_backend(projectile_id)
		return false
	return true


func has_fire_sorcerer_volley_replica(projectile_id: int) -> bool:
	var service: FireSorcererVolleySimulationService = (
		_known_replica_fire_sorcerer_volley_services.get(projectile_id)
	)
	var handle := int(_known_replica_fire_sorcerer_volley_handles.get(
		projectile_id,
		FireSorcererVolleySimulationService.INVALID_HANDLE
	))
	if (
		service == null
		or not is_instance_valid(service)
		or handle <= FireSorcererVolleySimulationService.INVALID_HANDLE
		or not service.is_handle_live(handle)
		or service.get_slot_mode(handle)
			!= FireSorcererVolleySimulationService.Mode.REPLICA
	):
		_erase_replica_fire_sorcerer_volley_backend(projectile_id)
		return false
	return true


func has_replica_projectile(projectile_id: int) -> bool:
	var service: RapidFireSimulationService = (
		_known_replica_projectile_services.get(projectile_id)
	)
	var handle := int(_known_replica_projectile_handles.get(
		projectile_id,
		RapidFireSimulationService.INVALID_HANDLE
	))
	if (
		service == null
		or not is_instance_valid(service)
		or handle <= RapidFireSimulationService.INVALID_HANDLE
		or not service.is_handle_live(handle)
		or service.get_slot_mode(handle) != RapidFireSimulationService.Mode.REPLICA
	):
		_erase_replica_projectile_backend(projectile_id)
		return false
	return true


func has_projectile_record(projectile_id: int) -> bool:
	return _projectile_records.has(projectile_id)


func get_projectile(projectile_id: int) -> Node:
	var projectile_variant: Variant = _known_projectiles.get(projectile_id)
	if projectile_variant == null or not is_instance_valid(projectile_variant):
		_known_projectiles.erase(projectile_id)
		return null
	return projectile_variant as Node


func apply_tiyi_sniper_hit_confirmation(
	projectile_id: int,
	enemy_net_id: int,
	hit_position: Vector2,
	direction: Vector2,
	continues_piercing: bool,
	presentation_parent: Node
) -> void:
	if (
		projectile_id <= 0
		or enemy_net_id <= 0
		or not _is_finite_vector2(hit_position)
		or presentation_parent == null
	):
		return
	var safe_direction := get_valid_client_projectile_direction(direction)
	if safe_direction == Vector2.ZERO:
		safe_direction = Vector2.RIGHT
	var projectile := get_projectile(projectile_id) as Node2D
	if projectile != null and projectile.has_method(
		"apply_authoritative_hit_confirmation"
	):
		projectile.call(
			"apply_authoritative_hit_confirmation",
			enemy_net_id,
			hit_position,
			safe_direction,
			continues_piercing
		)
		return
	var hit_effect_scene := _get_runtime_packed_scene(
		TIYI_SNIPER_HIT_EFFECT_SCENE_PATH
	)
	if hit_effect_scene == null:
		return
	var hit_effect := hit_effect_scene.instantiate() as Node2D
	if hit_effect == null:
		return
	hit_effect.top_level = true
	if hit_effect.has_method("setup"):
		hit_effect.call("setup", safe_direction)
	presentation_parent.add_child(hit_effect)
	hit_effect.global_position = hit_position


func receive_projectile_fired(
	projectile_id: int,
	projectile_type: StringName,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	pierces_enemies: bool,
	target_peer_id: int,
	target_enemy_net_id: int,
	compensation_age: float,
	now: float
) -> void:
	if not _NetConstants.is_valid_network_combat_value(damage):
		return
	if _is_fire_sorcerer_volley_type(projectile_type):
		_receive_fire_sorcerer_volley_replica(
			projectile_id,
			projectile_type,
			owner_peer_id,
			spawn_position,
			direction,
			damage,
			speed,
			lifetime,
			target_peer_id,
			target_enemy_net_id,
			compensation_age,
			now
		)
		return
	if has_data_projectile(projectile_id):
		return
	if _known_projectiles.has(projectile_id):
		_reconcile_predicted_projectile(
			projectile_id,
			owner_peer_id,
			projectile_type,
			direction,
			damage,
			speed,
			lifetime,
			pierces_enemies,
			target_enemy_net_id,
			now
		)
		return
	if _projectile_records.has(projectile_id):
		return
	_spawn_network_projectile(
		projectile_id,
		projectile_type,
		owner_peer_id,
		spawn_position,
		direction,
		damage,
		speed,
		lifetime,
		pierces_enemies,
		target_peer_id,
		target_enemy_net_id,
		compensation_age,
		now
	)


func _receive_fire_sorcerer_volley_replica(
	projectile_id: int,
	projectile_type: StringName,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	target_peer_id: int,
	target_enemy_net_id: int,
	compensation_age: float,
	now: float
) -> void:
	var projectile_namespace := owner_peer_id
	if projectile_namespace <= 0:
		projectile_namespace = PROJECTILE_ID_FALLBACK_OWNER_PEER_ID
	var profile := _get_fire_sorcerer_volley_profile(projectile_type)
	if (
		profile == FireSorcererVolleySimulationService.Profile.INVALID
		or not is_projectile_id_valid_for_host_owner(
			projectile_id,
			projectile_namespace
		)
		or has_fire_sorcerer_volley_data(projectile_id)
		or has_fire_sorcerer_volley_replica(projectile_id)
		or _known_projectiles.has(projectile_id)
		or _projectile_records.has(projectile_id)
		or not _is_finite_vector2(spawn_position)
		or not _is_finite_vector2(direction)
		or direction.length_squared() <= 0.001
		or not is_finite(speed)
		or speed <= 0.0
		or not is_finite(lifetime)
		or lifetime <= 0.0
		or not is_finite(compensation_age)
		or compensation_age < 0.0
		or target_peer_id < 0
		or target_enemy_net_id < 0
	):
		return
	var service := _get_fire_sorcerer_volley_simulation_service()
	if service == null:
		return
	var locked_direction := direction.normalized()
	var ball_positions := PackedVector2Array()
	var ball_directions := PackedVector2Array()
	ball_positions.resize(FireSorcererVolleySimulationService.BALL_COUNT)
	ball_directions.resize(FireSorcererVolleySimulationService.BALL_COUNT)
	for ball_index in range(FireSorcererVolleySimulationService.BALL_COUNT):
		ball_positions[ball_index] = spawn_position + (
			FIRE_SORCERER_VOLLEY_LOCAL_OFFSETS[ball_index].rotated(
				locked_direction.angle()
			)
		)
		ball_directions[ball_index] = locked_direction
	var target: Node2D = null
	if target_peer_id > 0:
		target = _get_player(target_peer_id)
	elif target_enemy_net_id > 0:
		target = _resolve_mode_world_target(target_enemy_net_id)
	var frozen_source := DamageSourceSnapshot.create(
		CombatRelationService.HOSTILE_WAVE,
		maxi(owner_peer_id, 0),
		0,
		projectile_id,
		projectile_type
	)
	var compensated_lifetime := maxf(lifetime - compensation_age, 0.01)
	var handle := service.register_volley(
		FireSorcererVolleySimulationService.Mode.REPLICA,
		profile,
		ball_positions,
		ball_directions,
		speed,
		compensated_lifetime,
		FIRE_SORCERER_VOLLEY_HOMING_TURN_RATE,
		damage,
		0,
		projectile_id,
		target,
		FIRE_SORCERER_VOLLEY_BURN_DURATION,
		_get_fire_sorcerer_volley_burn_level(profile),
		frozen_source
	)
	if handle <= FireSorcererVolleySimulationService.INVALID_HANDLE:
		return
	if compensation_age > 0.0 and not service.advance_compensated(
		handle,
		compensation_age
	):
		service.release_volley(handle)
		return
	_known_replica_fire_sorcerer_volley_services[projectile_id] = service
	_known_replica_fire_sorcerer_volley_handles[projectile_id] = handle
	remember_projectile_record(
		projectile_id,
		owner_peer_id,
		projectile_type,
		damage,
		lifetime,
		false,
		now,
		frozen_source
	)


func receive_tango_laser_volley(
	projectile_ids: PackedInt64Array,
	spawn_positions: PackedVector2Array,
	direction: Vector2,
	owner_peer_id: int,
	charge_sequence: int,
	current_charge_sequence: int,
	charge_ratio: float,
	barrage_remaining_seconds: float,
	damage: int,
	speed: float,
	lifetime: float,
	host_fire_timestamp: float,
	event_age: float,
	now: float
) -> int:
	if not is_valid_tango_laser_volley_payload(
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
		return current_charge_sequence
	for projectile_index in range(TANGO_LASER_VOLLEY_PROJECTILE_COUNT):
		var projectile_id := int(projectile_ids[projectile_index])
		if (
			has_projectile(projectile_id)
			or has_data_projectile(projectile_id)
			or has_projectile_record(projectile_id)
		):
			continue
		_spawn_network_projectile(
			projectile_id,
			TANGO_LASER_PROJECTILE_TYPE,
			owner_peer_id,
			spawn_positions[projectile_index],
			direction,
			damage,
			speed,
			lifetime,
			false,
			0,
			0,
			clampf(
				event_age,
				0.0,
				minf(PROJECTILE_TIME_COMPENSATION_MAX_SECONDS, lifetime)
			),
			now
		)
	return maxi(current_charge_sequence, charge_sequence)


func receive_linglan_skill1_ring(
	projectile_ids: PackedInt64Array,
	spawn_positions: PackedVector2Array,
	directions: PackedVector2Array,
	owner_peer_id: int,
	damage: int,
	speed: float,
	lifetime: float,
	host_fire_timestamp: float,
	event_age: float,
	now: float
) -> void:
	if not is_valid_linglan_skill1_ring_payload(
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
	var compensation_age := clampf(
		event_age,
		0.0,
		minf(PROJECTILE_TIME_COMPENSATION_MAX_SECONDS, lifetime)
	)
	for projectile_index in range(projectile_ids.size()):
		var projectile_id := int(projectile_ids[projectile_index])
		if (
			has_projectile(projectile_id)
			or has_data_projectile(projectile_id)
			or has_projectile_record(projectile_id)
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
			0,
			compensation_age,
			now
		)


static func _is_combat_robot_suicide_drone_type(
	projectile_type: StringName
) -> bool:
	return (
		projectile_type == COMBAT_ROBOT_SUICIDE_DRONE_TYPE
		or projectile_type == COMBAT_ROBOT_SUICIDE_DRONE_ELITE_TYPE
	)


func get_projectile_time_compensation_age(
	unbounded_event_age: float,
	lifetime: float,
	projectile_type: StringName = &""
) -> float:
	if _is_combat_robot_suicide_drone_type(projectile_type):
		return clampf(
			unbounded_event_age,
			0.0,
			(
				CombatRobotSuicideDrone.DEPLOY_DELAY
					+ maxf(lifetime, 0.0)
					+ CombatRobotSuicideDrone.EXPLOSION_DURATION
			)
		)
	return clampf(
		unbounded_event_age,
		0.0,
		minf(PROJECTILE_TIME_COMPENSATION_MAX_SECONDS, maxf(lifetime, 0.0))
	)


func prepare_enemy_hit(
	projectile_id: int,
	owner_peer_id: int,
	enemy_net_id: int,
	reported_damage: int,
	now: float
) -> EnemyHitAdmission:
	if (
		projectile_id <= 0
		or owner_peer_id <= 0
		or enemy_net_id <= 0
		or not is_projectile_id_valid_for_owner(projectile_id, owner_peer_id)
	):
		return null
	var record_variant: Variant = _projectile_records.get(projectile_id)
	if not (record_variant is Dictionary):
		return null
	var record := record_variant as Dictionary
	if record.is_empty() or int(record.get("owner_peer_id", 0)) != owner_peer_id:
		return null
	var projectile_type := StringName(record.get("projectile_type", &""))
	var consumes_first_hit := (
		(
			projectile_type == &"player_bullet"
			or projectile_type == TIYI_SNIPER_PROJECTILE_TYPE
			or projectile_type == TANGO_LASER_PROJECTILE_TYPE
		)
		and not bool(record.get("pierces_enemies", false))
	)
	if consumes_first_hit and bool(record.get("confirmed_hit_consumed", false)):
		return null
	var authoritative_damage := get_authoritative_projectile_damage(
		projectile_id,
		owner_peer_id,
		reported_damage,
		projectile_type
	)
	if authoritative_damage <= 0:
		return null
	var hit_key := "%d:%d" % [projectile_id, enemy_net_id]
	if _is_recent_event_cached(_processed_enemy_hit_ids, hit_key, now):
		return null
	var admission := EnemyHitAdmission.new()
	admission.projectile_type = projectile_type
	admission.authoritative_damage = authoritative_damage
	admission.consumes_first_confirmed_hit = consumes_first_hit
	return admission


func commit_enemy_hit(
	projectile_id: int,
	enemy_net_id: int,
	consumes_first_confirmed_hit: bool,
	now: float
) -> void:
	if consumes_first_confirmed_hit:
		var record_variant: Variant = _projectile_records.get(projectile_id)
		if record_variant is Dictionary:
			var record := record_variant as Dictionary
			record["confirmed_hit_consumed"] = true
			_projectile_records[projectile_id] = record
	_remember_recent_event(
		_processed_enemy_hit_ids,
		"%d:%d" % [projectile_id, enemy_net_id],
		HIT_DEDUP_RETENTION_SECONDS,
		now
	)


func get_projectile_record(projectile_id: int) -> Dictionary:
	var record_variant: Variant = _projectile_records.get(projectile_id)
	return record_variant as Dictionary if record_variant is Dictionary else {}


func get_projectile_damage_source_snapshot(
	projectile_id: int
) -> DamageSourceSnapshot:
	var record := get_projectile_record(projectile_id)
	if record.is_empty():
		return null
	var snapshot := DamageSourceSnapshot.create(
		int(record.get(
			"source_faction_id",
			CombatRelationService.PLAYER_ALLIED
		)),
		int(record.get("source_credit_peer_id", 0)),
		int(record.get("source_instigator_entity_id", 0)),
		int(record.get("source_event_id", projectile_id)),
		StringName(record.get(
			"source_type",
			record.get("projectile_type", &"")
		))
	)
	return snapshot if snapshot.is_valid() else null


func get_authoritative_projectile_damage(
	projectile_id: int,
	owner_peer_id: int,
	reported_damage: int,
	projectile_type: StringName = &"player_bullet"
) -> int:
	if not is_projectile_id_valid_for_owner(projectile_id, owner_peer_id):
		return -1
	var record := get_projectile_record(projectile_id)
	if not record.is_empty():
		if int(record.get("owner_peer_id", 0)) != owner_peer_id:
			return -1
		return int(record.get("damage", -1))
	return _get_bounded_player_projectile_damage(
		owner_peer_id,
		reported_damage,
		projectile_type
	)


func is_fire_sorcerer_fireball_contact_consumed(
	projectile_id: int,
	source_type: StringName
) -> bool:
	var source_bit := _get_fire_sorcerer_fireball_source_bit(source_type)
	if projectile_id <= 0 or source_bit == 0:
		return false
	var record := get_projectile_record(projectile_id)
	if (
		record.is_empty()
		or StringName(record.get("projectile_type", &""))
			!= _get_fire_sorcerer_projectile_type_for_source(source_type)
	):
		return false
	return (
		int(record.get(FIRE_SORCERER_CONSUMED_SOURCE_MASK_KEY, 0))
		& source_bit
	) != 0


func try_consume_fire_sorcerer_fireball_contact(
	projectile_id: int,
	source_type: StringName
) -> bool:
	var source_bit := _get_fire_sorcerer_fireball_source_bit(source_type)
	if projectile_id <= 0 or source_bit == 0:
		return false
	var record := get_projectile_record(projectile_id)
	if (
		record.is_empty()
		or StringName(record.get("projectile_type", &""))
			!= _get_fire_sorcerer_projectile_type_for_source(source_type)
	):
		return false
	var consumed_mask := int(record.get(
		FIRE_SORCERER_CONSUMED_SOURCE_MASK_KEY,
		0
	))
	if (consumed_mask & source_bit) != 0:
		return false
	record[FIRE_SORCERER_CONSUMED_SOURCE_MASK_KEY] = consumed_mask | source_bit
	_projectile_records[projectile_id] = record
	return true


func get_frost_ice_spike_record_damage(
	projectile_id: int,
	source_type: StringName
) -> int:
	var record := _get_frost_ice_spike_record(projectile_id, source_type)
	return int(record.get("damage", -1)) if not record.is_empty() else -1


func is_frost_ice_spike_contact_consumed(
	projectile_id: int,
	source_type: StringName
) -> bool:
	var record := _get_frost_ice_spike_record(projectile_id, source_type)
	return (
		not record.is_empty()
		and bool(record.get("confirmed_hit_consumed", false))
	)


func try_consume_frost_sorcerer_ice_spike_contact(
	projectile_id: int,
	source_type: StringName
) -> bool:
	var record := _get_frost_ice_spike_record(projectile_id, source_type)
	if record.is_empty() or bool(record.get("confirmed_hit_consumed", false)):
		return false
	record["confirmed_hit_consumed"] = true
	_projectile_records[projectile_id] = record
	return true


func prune_records(now: float) -> void:
	_stale_projectile_record_ids.clear()
	for projectile_id_variant in _projectile_records:
		var projectile_id := int(projectile_id_variant)
		var record := _projectile_records[projectile_id] as Dictionary
		if record.is_empty() or float(record.get("expires_at", 0.0)) <= now:
			_stale_projectile_record_ids.append(projectile_id)
	for projectile_id in _stale_projectile_record_ids:
		_projectile_records.erase(projectile_id)
	var expired_hit_keys: Array = []
	for hit_key in _processed_enemy_hit_ids:
		if float(_processed_enemy_hit_ids[hit_key]) <= now:
			expired_hit_keys.append(hit_key)
	for hit_key in expired_hit_keys:
		_processed_enemy_hit_ids.erase(hit_key)
	_prune_replica_projectile_backends(now)
	_prune_fire_sorcerer_volley_backends()


func _prune_fire_sorcerer_volley_backends() -> void:
	for projectile_id_variant in _known_fire_sorcerer_volley_services.keys():
		has_fire_sorcerer_volley_data(int(projectile_id_variant))
	for projectile_id_variant in (
		_known_replica_fire_sorcerer_volley_services.keys()
	):
		has_fire_sorcerer_volley_replica(int(projectile_id_variant))


func clear_peer(peer_id: int) -> void:
	_client_projectile_request_rate_buckets.erase(peer_id)
	_last_tango_volley_visual_state_by_peer.erase(peer_id)
	for projectile_id_variant in _reserved_host_projectile_ids.keys():
		var projectile_id := int(projectile_id_variant)
		if int(_reserved_host_projectile_ids[projectile_id]) == peer_id:
			_reserved_host_projectile_ids.erase(projectile_id)
	clear_projectiles_for_peer(peer_id)
	clear_data_projectiles_for_peer(peer_id)
	clear_fire_sorcerer_volleys_for_peer(peer_id)
	clear_projectile_records_for_peer(peer_id)


func clear_projectiles_for_peer(peer_id: int) -> void:
	var projectile_ids: Array[int] = []
	for projectile_id_variant in _known_projectiles.keys():
		var projectile_id := int(projectile_id_variant)
		var projectile := get_projectile(projectile_id)
		if projectile == null:
			projectile_ids.append(projectile_id)
			continue
		if int(projectile.get("owner_peer_id")) == peer_id:
			projectile_ids.append(projectile_id)
	for projectile_id in projectile_ids:
		var projectile := get_projectile(projectile_id)
		_known_projectiles.erase(projectile_id)
		if projectile == null:
			continue
		if projectile.has_method("retire"):
			projectile.call("retire")
		else:
			projectile.queue_free()


func clear_data_projectiles_for_peer(peer_id: int) -> void:
	var projectile_ids: Array[int] = []
	for projectile_id in _known_data_projectile_services:
		var record_variant: Variant = _projectile_records.get(projectile_id)
		var recorded_owner_peer_id := (
			int((record_variant as Dictionary).get("owner_peer_id", 0))
			if record_variant is Dictionary
			else decode_projectile_owner_peer_id(projectile_id)
		)
		if recorded_owner_peer_id == peer_id:
			projectile_ids.append(projectile_id)
	for projectile_id in projectile_ids:
		_release_and_erase_data_projectile_backend(projectile_id)


func clear_fire_sorcerer_volleys_for_peer(peer_id: int) -> void:
	var data_projectile_ids: Array[int] = []
	for projectile_id_variant in _known_fire_sorcerer_volley_services.keys():
		var projectile_id := int(projectile_id_variant)
		var record := get_projectile_record(projectile_id)
		if int(record.get("owner_peer_id", 0)) == peer_id:
			data_projectile_ids.append(projectile_id)
	for projectile_id in data_projectile_ids:
		_release_and_erase_fire_sorcerer_volley_backend(projectile_id)
	var replica_projectile_ids: Array[int] = []
	for projectile_id_variant in (
		_known_replica_fire_sorcerer_volley_services.keys()
	):
		var projectile_id := int(projectile_id_variant)
		var record := get_projectile_record(projectile_id)
		if int(record.get("owner_peer_id", 0)) == peer_id:
			replica_projectile_ids.append(projectile_id)
	for projectile_id in replica_projectile_ids:
		_release_and_erase_replica_fire_sorcerer_volley_backend(projectile_id)


func clear_projectile_records_for_peer(peer_id: int) -> void:
	var projectile_ids: Array[int] = []
	for projectile_id_variant in _projectile_records.keys():
		var projectile_id := int(projectile_id_variant)
		var record := _projectile_records[projectile_id] as Dictionary
		if record.is_empty() or int(record.get("owner_peer_id", 0)) == peer_id:
			projectile_ids.append(projectile_id)
	for projectile_id in projectile_ids:
		_projectile_records.erase(projectile_id)


func reset_session_state() -> void:
	for projectile_id_variant in _known_projectiles.keys():
		var projectile := get_projectile(int(projectile_id_variant))
		if projectile == null:
			continue
		if projectile.has_method("retire"):
			projectile.call("retire")
		else:
			projectile.queue_free()
	_known_projectiles.clear()
	for projectile_id in _known_data_projectile_services.keys():
		_release_and_erase_data_projectile_backend(projectile_id)
	_known_data_projectile_services.clear()
	_known_data_projectile_handles.clear()
	_known_data_projectile_types.clear()
	_known_data_projectile_owner_peer_ids.clear()
	_known_data_projectile_damages.clear()
	_known_data_projectile_lifetimes.clear()
	for projectile_id in _known_fire_sorcerer_volley_services.keys():
		_release_and_erase_fire_sorcerer_volley_backend(int(projectile_id))
	_known_fire_sorcerer_volley_services.clear()
	_known_fire_sorcerer_volley_handles.clear()
	_known_fire_sorcerer_volley_metadata.clear()
	for projectile_id in (
		_known_replica_fire_sorcerer_volley_services.keys()
	):
		_release_and_erase_replica_fire_sorcerer_volley_backend(
			int(projectile_id)
		)
	_known_replica_fire_sorcerer_volley_services.clear()
	_known_replica_fire_sorcerer_volley_handles.clear()
	_reserved_host_projectile_ids.clear()
	_active_enemy_rapid_fire_bursts.clear()
	_active_enemy_rapid_fire_base_by_reserved_id.clear()
	_pending_enemy_rapid_fire_finish_records.clear()
	_enemy_rapid_fire_finish_flush_queued = false
	for projectile_id in _known_replica_projectile_services.keys():
		_release_and_erase_replica_projectile_backend(int(projectile_id))
	_known_replica_projectile_services.clear()
	_known_replica_projectile_handles.clear()
	_known_replica_projectile_host_timestamps.clear()
	_seen_enemy_rapid_fire_projectile_expirations.clear()
	_finished_enemy_rapid_fire_projectile_timestamps.clear()
	_terminal_enemy_rapid_fire_source_expirations.clear()
	_terminal_enemy_rapid_fire_source_host_timestamps.clear()
	_stale_replica_projectile_ids.clear()
	_stale_enemy_rapid_fire_projectile_ids.clear()
	_stale_terminal_enemy_rapid_fire_source_ids.clear()
	_replica_prune_pass_count = 0
	_pending_enemy_rapid_fire_snapshots.clear()
	_projectile_records.clear()
	_stale_projectile_record_ids.clear()
	_processed_enemy_hit_ids.clear()
	_client_projectile_request_rate_buckets.clear()
	_last_tango_volley_visual_state_by_peer.clear()
	_next_projectile_sequence = 1
	_next_enemy_rapid_fire_snapshot_id = 1
	_latest_applied_enemy_rapid_fire_snapshot_id = 0
	_latest_applied_enemy_rapid_fire_snapshot_host_timestamp = -1.0


func get_state_metrics() -> Dictionary:
	return {
		"next_sequence": _next_projectile_sequence,
		"known_projectiles": _known_projectiles.size(),
		"known_data_projectiles": _known_data_projectile_services.size(),
		"known_fire_sorcerer_volley_data": (
			_known_fire_sorcerer_volley_services.size()
		),
		"known_fire_sorcerer_volley_replicas": (
			_known_replica_fire_sorcerer_volley_services.size()
		),
		"fire_sorcerer_volley_late_join_records": (
			_known_fire_sorcerer_volley_metadata.size()
		),
		"reserved_host_projectile_ids": _reserved_host_projectile_ids.size(),
		"active_enemy_rapid_fire_bursts": _active_enemy_rapid_fire_bursts.size(),
		"pending_enemy_rapid_fire_finishes": (
			_pending_enemy_rapid_fire_finish_records.size()
		),
		"known_replica_projectiles": _known_replica_projectile_services.size(),
		"terminal_rapid_fire_sources": (
			_terminal_enemy_rapid_fire_source_expirations.size()
		),
		"replica_prune_passes": _replica_prune_pass_count,
		"pending_rapid_fire_snapshots": _pending_enemy_rapid_fire_snapshots.size(),
		"latest_rapid_fire_snapshot_id": _latest_applied_enemy_rapid_fire_snapshot_id,
		"projectile_records": _projectile_records.size(),
		"request_rate_buckets": _client_projectile_request_rate_buckets.size(),
		"enemy_hit_dedupe": _processed_enemy_hit_ids.size(),
		"tango_visual_peers": _last_tango_volley_visual_state_by_peer.size(),
	}


static func is_projectile_id_valid_for_owner(
	projectile_id: int,
	owner_peer_id: int
) -> bool:
	return (
		owner_peer_id > 0
		and owner_peer_id <= PROJECTILE_ID_MAX_OWNER_PEER_ID
		and decode_projectile_owner_peer_id(projectile_id) == owner_peer_id
		and decode_projectile_sequence(projectile_id) > 0
	)


static func is_projectile_id_valid_for_client_owner(
	projectile_id: int,
	owner_peer_id: int
) -> bool:
	return (
		is_projectile_id_valid_for_owner(projectile_id, owner_peer_id)
		and not is_host_origin_projectile_id(projectile_id)
	)


static func is_projectile_id_valid_for_host_owner(
	projectile_id: int,
	owner_peer_id: int
) -> bool:
	return (
		is_projectile_id_valid_for_owner(projectile_id, owner_peer_id)
		and is_host_origin_projectile_id(projectile_id)
	)


static func encode_projectile_id(owner_peer_id: int, sequence: int) -> int:
	if (
		owner_peer_id <= 0
		or owner_peer_id > PROJECTILE_ID_MAX_OWNER_PEER_ID
		or sequence <= 0
		or sequence > PROJECTILE_ID_SEQUENCE_MASK
	):
		return 0
	return (owner_peer_id << PROJECTILE_ID_SEQUENCE_BITS) | sequence


static func decode_projectile_owner_peer_id(projectile_id: int) -> int:
	return projectile_id >> PROJECTILE_ID_SEQUENCE_BITS if projectile_id > 0 else 0


static func decode_projectile_sequence(projectile_id: int) -> int:
	return projectile_id & PROJECTILE_ID_SEQUENCE_MASK if projectile_id > 0 else 0


static func decode_projectile_sequence_counter(projectile_id: int) -> int:
	return decode_projectile_sequence(projectile_id) & PROJECTILE_ID_SEQUENCE_COUNTER_MASK


static func is_host_origin_projectile_id(projectile_id: int) -> bool:
	return (
		decode_projectile_sequence(projectile_id)
		& PROJECTILE_ID_HOST_ORIGIN_BIT
	) != 0


static func get_valid_client_projectile_direction(direction: Vector2) -> Vector2:
	if not _is_finite_vector2(direction):
		return Vector2.ZERO
	var direction_length := direction.length()
	if (
		direction_length < CLIENT_PROJECTILE_DIRECTION_MIN_LENGTH
		or direction_length > CLIENT_PROJECTILE_DIRECTION_MAX_LENGTH
	):
		return Vector2.ZERO
	return direction / direction_length


static func is_valid_tango_laser_volley_payload(
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
	if (
		projectile_ids.size() != TANGO_LASER_VOLLEY_PROJECTILE_COUNT
		or spawn_positions.size() != TANGO_LASER_VOLLEY_PROJECTILE_COUNT
		or owner_peer_id <= 0
		or charge_sequence <= 0
		or not is_finite(charge_ratio)
		or charge_ratio < 0.0
		or charge_ratio > 1.0
		or not is_finite(barrage_remaining_seconds)
		or barrage_remaining_seconds < 0.0
		or barrage_remaining_seconds > 5.0
		or not _NetConstants.is_valid_network_combat_value(damage)
		or not _is_finite_vector2(direction)
		or direction.length_squared() <= 0.001
		or not is_finite(speed)
		or speed <= 0.0
		or not is_finite(lifetime)
		or lifetime <= 0.0
		or not is_finite(host_fire_timestamp)
		or host_fire_timestamp < 0.0
	):
		return false
	var seen_projectile_ids: Dictionary[int, bool] = {}
	for projectile_index in range(TANGO_LASER_VOLLEY_PROJECTILE_COUNT):
		var projectile_id := int(projectile_ids[projectile_index])
		if (
			seen_projectile_ids.has(projectile_id)
			or not is_projectile_id_valid_for_host_owner(
				projectile_id,
				owner_peer_id
			)
			or not _is_finite_vector2(spawn_positions[projectile_index])
		):
			return false
		seen_projectile_ids[projectile_id] = true
	return true


static func is_valid_linglan_skill1_ring_payload(
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
		or not _NetConstants.is_valid_network_combat_value(damage)
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
			or not is_projectile_id_valid_for_host_owner(
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


func instantiate_projectile(
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
	if not is_bound():
		return null
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
			if target_enemy_net_id > 0:
				bullet.setup_homing(_runtime.get_enemy_for_net_id(target_enemy_net_id))
			bullet.speed = speed
			bullet.max_lifetime = lifetime
			bullet.remaining_lifetime = lifetime
			return bullet
		TANGO_LASER_PROJECTILE_TYPE:
			var laser_scene := _get_runtime_packed_scene(
				TANGO_LASER_BULLET_SCENE_PATH
			)
			if laser_scene == null:
				return null
			var laser := _acquire_or_instantiate_projectile(laser_scene) as Bullet
			if laser == null:
				return null
			laser.top_level = true
			laser.setup(direction, damage, false)
			laser.speed = speed
			laser.max_lifetime = lifetime
			laser.remaining_lifetime = lifetime
			laser.setup_collectible_owner(_get_player(owner_peer_id))
			return laser
		TIYI_SNIPER_PROJECTILE_TYPE:
			var sniper_scene := _get_runtime_packed_scene(
				TIYI_SNIPER_BULLET_SCENE_PATH
			)
			if sniper_scene == null:
				return null
			var sniper := _acquire_or_instantiate_projectile(sniper_scene) as Bullet
			if sniper == null:
				return null
			sniper.top_level = true
			sniper.setup(direction, damage, pierces_enemies)
			if target_enemy_net_id > 0:
				sniper.setup_homing(_runtime.get_enemy_for_net_id(target_enemy_net_id))
			sniper.speed = speed
			sniper.max_lifetime = lifetime
			sniper.remaining_lifetime = lifetime
			return sniper
		&"collectible_arrow":
			var arrow := _acquire_or_instantiate_projectile(
				COLLECTIBLE_ARROW_PROJECTILE_SCENE
			)
			if arrow == null:
				return null
			arrow.top_level = true
			arrow.call("setup", direction, damage)
			arrow.set("speed", speed)
			arrow.set("max_lifetime", lifetime)
			arrow.set("remaining_lifetime", lifetime)
			return arrow
		&"skill1_bomb":
			var bomb_scene := _get_runtime_packed_scene(SKILL1_BOMB_SCENE_PATH)
			if bomb_scene == null:
				return null
			var bomb := bomb_scene.instantiate() as Node2D
			if bomb == null:
				return null
			bomb.top_level = true
			bomb.call(
				"setup",
				_get_player(owner_peer_id),
				direction,
				damage
			)
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
			if not _prepare_enemy_network_projectile(capoo_bullet):
				_release_projectile(capoo_bullet)
				return null
			capoo_bullet.setup(
				direction,
				damage,
				speed,
				lifetime,
				_runtime.grid_pathfinder as GridPathfinder,
				_runtime.capoo_projectile_motion_system
			)
			return capoo_bullet
		&"combat_robot_gunner_bullet", &"combat_robot_gunner_elite_bullet":
			var gunner_bullet_scene := (
				COMBAT_ROBOT_GUNNER_ELITE_BULLET_SCENE
				if projectile_type == &"combat_robot_gunner_elite_bullet"
				else COMBAT_ROBOT_GUNNER_BULLET_SCENE
			)
			var gunner_bullet := (
				_acquire_or_instantiate_projectile(
					gunner_bullet_scene
				)
				as CombatRobotGunnerBullet
			)
			if gunner_bullet == null:
				return null
			gunner_bullet.top_level = true
			var gateway := _runtime.get_multiplayer_gameplay_gateway()
			var projectile_parent := (
				gateway.get_projectile_parent() if gateway != null else null
			)
			if gateway == null or projectile_parent == null:
				_release_projectile(gunner_bullet)
				return null
			gunner_bullet.bind_gameplay_context(_runtime, gateway)
			if gunner_bullet.get_parent() == null:
				projectile_parent.add_child(gunner_bullet)
			elif gunner_bullet.get_parent() != projectile_parent:
				gunner_bullet.reparent(projectile_parent)
			gunner_bullet.setup(
				direction,
				damage,
				speed,
				lifetime,
				_runtime.grid_pathfinder as GridPathfinder,
				_runtime.capoo_projectile_motion_system
			)
			return gunner_bullet
		COMBAT_ROBOT_SUICIDE_DRONE_TYPE, COMBAT_ROBOT_SUICIDE_DRONE_ELITE_TYPE:
			if _runtime.combat_robot_drone_motion_system == null:
				return null
			var drone_scene := (
				COMBAT_ROBOT_SUICIDE_DRONE_ELITE_SCENE
				if projectile_type == COMBAT_ROBOT_SUICIDE_DRONE_ELITE_TYPE
				else COMBAT_ROBOT_SUICIDE_DRONE_SCENE
			)
			var drone := (
				_acquire_or_instantiate_projectile(
					drone_scene
				)
				as CombatRobotSuicideDrone
			)
			if drone == null:
				return null
			drone.top_level = true
			var gateway := _runtime.get_multiplayer_gameplay_gateway()
			var projectile_parent := (
				gateway.get_projectile_parent() if gateway != null else null
			)
			if gateway == null or projectile_parent == null:
				_release_projectile(drone)
				return null
			drone.bind_gameplay_context(_runtime, gateway)
			if drone.get_parent() == null:
				projectile_parent.add_child(drone)
			elif drone.get_parent() != projectile_parent:
				drone.reparent(projectile_parent)
			drone.setup(
				direction,
				damage,
				speed,
				lifetime,
				CombatRobotSuicideDrone.DEFAULT_EXPLOSION_RADIUS,
				_runtime.combat_robot_drone_motion_system
			)
			return drone
		&"capoo_rpg_rocket":
			var rocket := (
				_acquire_or_instantiate_projectile(CAPOO_RPG_ROCKET_SCENE)
				as CapooRPGRocket
			)
			if rocket == null:
				return null
			rocket.top_level = true
			if not _prepare_enemy_network_projectile(rocket):
				_release_projectile(rocket)
				return null
			rocket.setup(direction, damage, speed, lifetime)
			return rocket
		&"capoo_mage_fireball":
			var fireball := (
				_acquire_or_instantiate_projectile(CAPOO_MAGE_FIREBALL_SCENE)
				as CapooMageFireball
			)
			if fireball == null:
				return null
			fireball.top_level = true
			if not _prepare_enemy_network_projectile(fireball):
				_release_projectile(fireball)
				return null
			var fireball_target: Node2D = null
			if target_peer_id > 0:
				fireball_target = _get_player(target_peer_id)
			elif target_enemy_net_id > 0:
				fireball_target = _resolve_mode_world_target(target_enemy_net_id)
			fireball.setup(
				direction,
				damage,
				speed,
				lifetime,
				fireball.fireball_radius,
				fireball_target,
				fireball.homing_turn_rate
			)
			return fireball
		FIRE_SORCERER_FIREBALL_VOLLEY_TYPE, \
		FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_TYPE:
			var volley_scene := (
				FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_SCENE
				if projectile_type == FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_TYPE
				else FIRE_SORCERER_FIREBALL_VOLLEY_SCENE
			)
			var volley := (
				_acquire_or_instantiate_projectile(volley_scene)
				as FireSorcererFireballVolley
			)
			if volley == null:
				return null
			volley.top_level = true
			if not _prepare_enemy_network_projectile(volley):
				_release_projectile(volley)
				return null
			var target: Node2D = null
			if target_peer_id > 0:
				target = _get_player(target_peer_id)
			elif target_enemy_net_id > 0:
				target = _resolve_mode_world_target(target_enemy_net_id)
			volley.setup(
				direction,
				damage,
				speed,
				lifetime,
				target,
				6.0,
				_runtime
			)
			return volley
		&"capoo_smg_bullet":
			var smg_bullet := (
				_acquire_or_instantiate_projectile(CAPOO_SMG_BULLET_SCENE)
				as CapooAK47Bullet
			)
			if smg_bullet == null:
				return null
			smg_bullet.top_level = true
			if not _prepare_enemy_network_projectile(smg_bullet):
				_release_projectile(smg_bullet)
				return null
			smg_bullet.setup(
				direction,
				damage,
				speed,
				lifetime,
				_runtime.grid_pathfinder as GridPathfinder,
				_runtime.capoo_projectile_motion_system
			)
			return smg_bullet
		&"yuanshi_fire_projectile":
			var fire_projectile := (
				_acquire_or_instantiate_projectile(
					YUANSHI_FIRE_PROJECTILE_SCENE
				)
				as YuanshiInsectFireProjectile
			)
			if fire_projectile == null:
				return null
			fire_projectile.top_level = true
			if not _prepare_enemy_network_projectile(fire_projectile):
				_release_projectile(fire_projectile)
				return null
			fire_projectile.setup(direction, damage, speed, lifetime)
			return fire_projectile
		FROST_SORCERER_ICE_SPIKE_TYPE:
			var spike := (
				_acquire_or_instantiate_projectile(
					FROST_SORCERER_ICE_SPIKE_SCENE
				)
				as FrostSorcererIceSpike
			)
			if spike == null:
				return null
			spike.top_level = true
			if not _prepare_enemy_network_projectile(spike):
				_release_projectile(spike)
				return null
			spike.setup(direction, damage, speed, lifetime)
			return spike
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
			if not _bind_linglan_projectile_gameplay_context(sakura_bullet):
				_release_projectile(sakura_bullet)
				return null
			sakura_bullet.setup(direction, damage, speed, lifetime)
			return sakura_bullet
		&"linglan_skill2_rocket":
			_ensure_linglan_projectile_resources(projectile_type)
			if _linglan_skill2_rocket_scene == null or _linglan_skill2_config == null:
				return null
			var sakura_rocket := (
				_linglan_skill2_rocket_scene.instantiate()
				as LinglanSkill2SakuraRocket
			)
			if sakura_rocket == null:
				return null
			sakura_rocket.top_level = true
			if not _bind_linglan_projectile_gameplay_context(sakura_rocket):
				sakura_rocket.queue_free()
				return null
			sakura_rocket.setup(
				direction,
				damage,
				speed,
				lifetime,
				float(_linglan_skill2_config.get("rocket_explosion_radius")),
				_get_player(target_peer_id) if target_peer_id > 0 else null,
				float(_linglan_skill2_config.get("rocket_homing_turn_rate"))
			)
			return sakura_rocket
		&"collectible_sakura_rocket":
			_ensure_linglan_projectile_resources(projectile_type)
			if _collectible_sakura_rocket_scene == null:
				return null
			var collectible_rocket := (
				_acquire_or_instantiate_projectile(
					_collectible_sakura_rocket_scene
				)
				as LinglanSkill2SakuraRocket
			)
			if collectible_rocket == null:
				return null
			collectible_rocket.top_level = true
			if not _bind_linglan_projectile_gameplay_context(collectible_rocket):
				_release_projectile(collectible_rocket)
				return null
			var target_enemy: Enemy = null
			if target_enemy_net_id > 0:
				target_enemy = _runtime.get_enemy_for_net_id(target_enemy_net_id)
			collectible_rocket.setup(
				direction,
				damage,
				speed,
				lifetime,
				collectible_rocket.explosion_radius,
				null,
				collectible_rocket.homing_turn_rate,
				target_enemy,
				true,
				EnemyConfig.DamageType.MAGIC
			)
			return collectible_rocket
		&"linglan_skill3_orb":
			_ensure_linglan_projectile_resources(projectile_type)
			if _linglan_skill3_orb_scene == null or _linglan_skill3_config == null:
				return null
			var light_orb := (
				_linglan_skill3_orb_scene.instantiate()
				as LinglanSkill3LightOrb
			)
			if light_orb == null:
				return null
			light_orb.top_level = true
			if not _bind_linglan_projectile_gameplay_context(light_orb):
				light_orb.queue_free()
				return null
			light_orb.setup(
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
			var skill4_orb := (
				_linglan_skill4_orb_scene.instantiate()
				as LinglanSkill4LightOrb
			)
			if skill4_orb == null:
				return null
			skill4_orb.top_level = true
			if not _bind_linglan_projectile_gameplay_context(skill4_orb):
				skill4_orb.queue_free()
				return null
			skill4_orb.setup(
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


func get_authoritative_client_projectile_parameters(
	projectile_type: StringName,
	owner_peer_id: int
) -> Dictionary:
	var owner_player := _get_player(owner_peer_id)
	if owner_player == null:
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
			var defaults := _get_cached_projectile_defaults(
				projectile_type,
				bullet_scene
			)
			if defaults.is_empty():
				return {}
			return {
				"damage": owner_player.get_outgoing_damage(
					owner_player.attack_damage,
					EnemyConfig.DamageType.PHYSICAL
				),
				"speed": float(defaults["speed"]),
				"lifetime": float(defaults["lifetime"]),
				"pierces_enemies": (
					randf() < owner_player.get_inventory_bullet_pierce_chance()
				),
				"homes_to_enemy": (
					randf() < owner_player._get_inventory_bullet_homing_chance()
				),
			}
		TIYI_SNIPER_PROJECTILE_TYPE:
			var tiyi_player := owner_player as PlayerTiyi
			if (
				tiyi_player == null
				or not _is_valid_tiyi_player(owner_player)
				or not owner_player.can_request_multiplayer_projectile(projectile_type)
				or not owner_player.has_method("try_accept_authoritative_primary_shot")
			):
				return {}
			# 与本地逐发构造顺序保持一致：先快照技能租约，再执行会消耗弹药并
			# 触发攻击收藏品的 Host 原子准入，避免同步副作用改写当前这一发。
			var guaranteed_piercing := (
				tiyi_player.has_guaranteed_primary_projectile_piercing()
			)
			if not bool(owner_player.call(
				"try_accept_authoritative_primary_shot",
				projectile_type
			)):
				return {}
			var sniper_scene := _get_runtime_packed_scene(
				TIYI_SNIPER_BULLET_SCENE_PATH
			)
			var defaults := _get_cached_projectile_defaults(
				projectile_type,
				sniper_scene
			)
			if defaults.is_empty():
				return {}
			return {
				"damage": owner_player.get_outgoing_damage(
					owner_player.attack_damage,
					EnemyConfig.DamageType.MAGIC
				),
				"speed": float(defaults["speed"]),
				"lifetime": float(defaults["lifetime"]),
				"pierces_enemies": (
					guaranteed_piercing
					or randf() < owner_player.get_inventory_bullet_pierce_chance()
				),
				"homes_to_enemy": (
					randf() < owner_player._get_inventory_bullet_homing_chance()
				),
			}
		&"skill1_bomb":
			if not owner_player.can_request_multiplayer_projectile(projectile_type):
				return {}
			var bomb_scene := _get_runtime_packed_scene(SKILL1_BOMB_SCENE_PATH)
			if bomb_scene == null:
				return {}
			var bomb := bomb_scene.instantiate() as Node2D
			if bomb == null:
				return {}
			if not owner_player.consume_multiplayer_skill1_charge():
				bomb.free()
				return {}
			owner_player.activate_collectible_skill_effects_from_multiplayer()
			var result := {
				"damage": owner_player.get_skill1_projectile_damage(),
				"speed": float(bomb.get("speed")),
				"lifetime": float(bomb.get("max_lifetime")),
			}
			bomb.free()
			return result
		_:
			return {}


func is_client_projectile_spawn_position_allowed(
	projectile_type: StringName,
	owner_peer_id: int,
	spawn_position: Vector2,
	accepted_player_position: Variant,
	tolerance: float
) -> bool:
	if not _is_finite_vector2(spawn_position):
		return false
	var owner_player := _get_player(owner_peer_id)
	if owner_player == null:
		return false
	var spawn_distance := owner_player.get_multiplayer_projectile_spawn_distance(
		projectile_type
	)
	if spawn_distance <= 0.0:
		return false
	var allowed_distance := tolerance + spawn_distance
	if owner_player.global_position.distance_to(spawn_position) <= allowed_distance:
		return true
	return (
		accepted_player_position is Vector2
		and (accepted_player_position as Vector2).distance_to(spawn_position)
			<= allowed_distance
	)


func get_authoritative_client_projectile_spawn_position(
	projectile_type: StringName,
	owner_peer_id: int,
	_reported_spawn_position: Vector2,
	accepted_direction: Vector2
) -> Vector2:
	var owner_player := _get_player(owner_peer_id)
	if (
		owner_player == null
		or not is_instance_valid(owner_player)
		or accepted_direction == Vector2.ZERO
		or (
			projectile_type == TIYI_SNIPER_PROJECTILE_TYPE
			and not _is_valid_tiyi_player(owner_player)
		)
	):
		return Vector2(INF, INF)
	var muzzle_distance := owner_player.get_multiplayer_projectile_spawn_distance(
		projectile_type
	)
	if muzzle_distance <= 0.0:
		return Vector2(INF, INF)
	return owner_player.global_position + accepted_direction * muzzle_distance


func resolve_authoritative_homing_target(
	owner_peer_id: int,
	direction: Vector2,
	should_home: bool
) -> int:
	if not should_home:
		return 0
	var owner_player := _get_player(owner_peer_id)
	if owner_player == null:
		return 0
	var target := owner_player._find_homing_bullet_target(direction)
	if target == null or not is_instance_valid(target) or target.is_dead:
		return 0
	return int(target.get_meta("net_id", 0))


func _get_runtime_packed_scene(path: String) -> PackedScene:
	var cached_scene := _runtime_scene_cache.get(path) as PackedScene
	if cached_scene != null:
		return cached_scene
	var loaded_scene := load(path) as PackedScene
	if loaded_scene != null:
		_runtime_scene_cache[path] = loaded_scene
	return loaded_scene


func _acquire_or_instantiate_projectile(scene: PackedScene) -> Node:
	if scene == null or not is_bound():
		return null
	if _runtime.has_session_object_pool_scene(scene):
		return _runtime.acquire_session_object(scene, false)
	return scene.instantiate()


func _bind_linglan_projectile_gameplay_context(projectile: Node) -> bool:
	if projectile == null or not is_instance_valid(projectile) or not is_bound():
		return false
	var gateway := _runtime.get_multiplayer_gameplay_gateway()
	if gateway == null:
		return false
	var projectile_parent := gateway.get_projectile_parent()
	if projectile_parent == null:
		return false
	var context_bound := false
	var skill1_bullet := projectile as LinglanSakuraBullet
	if skill1_bullet != null:
		skill1_bullet.bind_gameplay_context(_runtime, gateway)
		context_bound = true
	var skill2_rocket := projectile as LinglanSkill2SakuraRocket
	if skill2_rocket != null:
		skill2_rocket.bind_gameplay_context(_runtime, gateway)
		context_bound = true
	var skill3_orb := projectile as LinglanSkill3LightOrb
	if skill3_orb != null:
		skill3_orb.bind_gameplay_context(_runtime, gateway)
		context_bound = true
	var skill4_orb := projectile as LinglanSkill4LightOrb
	if skill4_orb != null:
		skill4_orb.bind_gameplay_context(_runtime, gateway)
		context_bound = true
	if not context_bound:
		return false
	if projectile.get_parent() == null:
		projectile_parent.add_child(projectile)
	elif (
		projectile.get_parent() != projectile_parent
		and not _runtime.is_ancestor_of(projectile)
	):
		return false
	return true


func _prepare_enemy_network_projectile(projectile: Node) -> bool:
	if projectile == null or not is_instance_valid(projectile) or not is_bound():
		return false
	var gateway := _runtime.get_multiplayer_gameplay_gateway()
	if gateway == null:
		return false
	var capoo_bullet := projectile as CapooAK47Bullet
	var rpg_rocket := projectile as CapooRPGRocket
	var mage_fireball := projectile as CapooMageFireball
	var sorcerer_volley := projectile as FireSorcererFireballVolley
	var yuanshi_fire := projectile as YuanshiInsectFireProjectile
	var frost_spike := projectile as FrostSorcererIceSpike
	if capoo_bullet != null:
		capoo_bullet.bind_gameplay_context(_runtime, gateway)
	elif rpg_rocket != null:
		rpg_rocket.bind_gameplay_context(_runtime, gateway)
	elif mage_fireball != null:
		mage_fireball.bind_gameplay_context(_runtime, gateway)
	elif sorcerer_volley != null:
		sorcerer_volley.bind_gameplay_context(_runtime, gateway)
	elif yuanshi_fire != null:
		yuanshi_fire.bind_gameplay_context(_runtime, gateway)
	elif frost_spike != null:
		frost_spike.bind_gameplay_context(_runtime, gateway)
	else:
		return false
	var projectile_parent := gateway.get_projectile_parent()
	if projectile_parent == null:
		return false
	if projectile.get_parent() == null:
		projectile_parent.add_child(projectile)
	elif projectile.get_parent() != projectile_parent:
		projectile.reparent(projectile_parent)
	return true


func _get_cached_projectile_defaults(
	projectile_type: StringName,
	scene: PackedScene
) -> Dictionary:
	var cached := _projectile_default_parameter_cache.get(
		projectile_type,
		{}
	) as Dictionary
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


func _resolve_mode_world_target(net_id: int) -> Node2D:
	if not is_bound() or net_id <= 0:
		return null
	var adapter := _runtime.get_multiplayer_mode_adapter()
	return (
		adapter.get_network_projectile_world_target(net_id)
		if adapter != null
		else null
	)


static func _is_valid_tiyi_player(player: Player) -> bool:
	return (
		player != null
		and is_instance_valid(player)
		and player.has_method("is_tiyi")
		and bool(player.call("is_tiyi"))
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
	pierces_enemies: bool,
	target_peer_id: int,
	target_enemy_net_id: int,
	compensation_age: float,
	now: float
) -> void:
	if (
		projectile_id <= 0
		or _known_projectiles.has(projectile_id)
		or has_data_projectile(projectile_id)
		or has_fire_sorcerer_volley_data(projectile_id)
		or has_fire_sorcerer_volley_replica(projectile_id)
		or _projectile_records.has(projectile_id)
	):
		return
	var projectile := instantiate_projectile(
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
	if not bind_player_projectile_gameplay_context(projectile):
		_release_projectile(projectile)
		return
	setup_projectile_network_identity(
		projectile,
		projectile_id,
		owner_peer_id,
		projectile_type
	)
	_known_projectiles[projectile_id] = projectile
	remember_projectile_record(
		projectile_id,
		owner_peer_id,
		projectile_type,
		damage,
		lifetime,
		pierces_enemies,
		now
	)
	if projectile.get_parent() == null:
		var projectile_parent := _get_projectile_parent()
		if projectile_parent == null:
			_known_projectiles.erase(projectile_id)
			_release_projectile(projectile)
			return
		projectile_parent.add_child(projectile)
	var projectile_2d := projectile as Node2D
	if projectile_2d == null:
		_known_projectiles.erase(projectile_id)
		_release_projectile(projectile)
		return
	projectile_2d.global_position = spawn_position
	projectile_2d.reset_physics_interpolation()
	if (
		projectile.has_method("simulate_compensated_motion")
		and (
			compensation_age > 0.0
			or _is_combat_robot_suicide_drone_type(projectile_type)
		)
	):
		projectile.call("simulate_compensated_motion", compensation_age)
	else:
		projectile_2d.global_position += (
			direction.normalized() * maxf(speed, 0.0) * compensation_age
		)
	apply_projectile_lifetime_compensation(
		projectile,
		lifetime,
		compensation_age,
		projectile_type
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
	target_enemy_net_id: int,
	now: float
) -> void:
	var projectile := get_projectile(projectile_id)
	if projectile == null:
		return
	var bullet := projectile as Bullet
	if bullet != null:
		bullet.setup(direction, damage, pierces_enemies)
		bullet.speed = maxf(speed, 0.0)
		bullet.max_lifetime = maxf(lifetime, 0.01)
		bullet.remaining_lifetime = minf(
			bullet.remaining_lifetime,
			bullet.max_lifetime
		)
		var homing_target: Enemy = null
		if is_bound() and target_enemy_net_id > 0:
			homing_target = _runtime.get_enemy_for_net_id(target_enemy_net_id)
		bullet.setup_homing(homing_target)
	remember_projectile_record(
		projectile_id,
		owner_peer_id,
		projectile_type,
		damage,
		lifetime,
		pierces_enemies,
		now
	)
	var confirmed_record := get_projectile_record(projectile_id)
	if not confirmed_record.is_empty():
		confirmed_record["authority_confirmed"] = true
		_projectile_records[projectile_id] = confirmed_record
	if projectile_type == &"skill1_bomb":
		var owner_player := _get_player(owner_peer_id)
		if owner_player != null:
			owner_player.confirm_predicted_void_battery_activation(
				projectile.get_instance_id()
			)


func remember_projectile_record(
	projectile_id: int,
	owner_peer_id: int,
	projectile_type: StringName,
	damage: int,
	lifetime: float,
	pierces_enemies: bool,
	now: float,
	source_snapshot: DamageSourceSnapshot = null
) -> void:
	if projectile_id <= 0:
		return
	var frozen_source := (
		source_snapshot.duplicate_snapshot()
		if source_snapshot != null and source_snapshot.is_valid()
		else DamageSourceSnapshot.create(
			CombatRelationService.PLAYER_ALLIED,
			maxi(owner_peer_id, 0),
			maxi(owner_peer_id, 0),
			projectile_id,
			projectile_type
		)
	)
	var frozen_event_id := (
		frozen_source.event_source_id
		if frozen_source.event_source_id > 0
		else projectile_id
	)
	var record := {
		"owner_peer_id": owner_peer_id,
		"projectile_type": projectile_type,
		# Player projectiles freeze attribution at launch. These value fields are
		# retained in the Host record instead of consulting the owner at impact.
		"source_faction_id": frozen_source.source_faction_id,
		"source_credit_peer_id": frozen_source.credit_peer_id,
		"source_instigator_entity_id": frozen_source.instigator_entity_id,
		"source_event_id": frozen_event_id,
		"source_type": (
			frozen_source.source_type
			if frozen_source.source_type != &""
			else projectile_type
		),
		"damage": maxi(damage, 0),
		"pierces_enemies": pierces_enemies,
		"confirmed_hit_consumed": false,
		"authority_confirmed": false,
		"expires_at": now + maxf(lifetime, 0.0) + PROJECTILE_RECORD_RETENTION_SECONDS,
	}
	if _is_fire_sorcerer_volley_type(projectile_type):
		record[FIRE_SORCERER_CONSUMED_SOURCE_MASK_KEY] = 0
	_projectile_records[projectile_id] = record


func setup_projectile_network_identity(
	projectile: Node,
	projectile_id: int,
	owner_peer_id: int,
	projectile_type: StringName
) -> void:
	bind_player_projectile_gameplay_context(projectile)
	if projectile.has_method("setup_multiplayer"):
		projectile.call(
			"setup_multiplayer",
			projectile_id,
			owner_peer_id,
			projectile_type
		)
	if projectile.has_signal(&"projectile_finished"):
		var finished_callable := Callable(self, "_on_network_projectile_finished")
		if not projectile.is_connected(&"projectile_finished", finished_callable):
			projectile.connect(&"projectile_finished", finished_callable)
	if not projectile.has_meta(SessionObjectPool.POOL_OWNER_META):
		projectile.tree_exited.connect(
			_on_network_projectile_tree_exited.bind(projectile_id, projectile),
			CONNECT_ONE_SHOT
		)


func bind_player_projectile_gameplay_context(projectile: Node) -> bool:
	if projectile == null or not is_instance_valid(projectile):
		return false
	var player_projectile := false
	var gateway: MultiplayerGameplayGateway = null
	if is_bound():
		gateway = _runtime.get_multiplayer_gameplay_gateway()
	var bullet := projectile as Bullet
	if bullet != null:
		player_projectile = true
		bullet.bind_gameplay_context(_runtime, gateway)
	var arrow := projectile as CollectibleArrowProjectile
	if arrow != null:
		player_projectile = true
		arrow.bind_gameplay_context(_runtime, gateway)
	var bomb := projectile as WeishidaierSkill1Bomb
	if bomb != null:
		player_projectile = true
		bomb.bind_gameplay_context(_runtime, gateway)
	if not player_projectile:
		return true
	if not is_bound() or gateway == null:
		return false
	var projectile_parent := gateway.get_projectile_parent()
	if projectile_parent == null:
		return false
	if projectile.get_parent() == null:
		projectile_parent.add_child(projectile)
	elif projectile.get_parent() != projectile_parent:
		projectile.reparent(projectile_parent)
	return true


func apply_projectile_lifetime_compensation(
	projectile: Node,
	lifetime: float,
	compensation_age: float,
	projectile_type: StringName
) -> void:
	if projectile == null or compensation_age <= 0.0:
		return
	if _is_combat_robot_suicide_drone_type(projectile_type):
		return
	var view_bounded := (
		projectile_type == &"player_bullet"
		or projectile_type == TIYI_SNIPER_PROJECTILE_TYPE
		or projectile_type == TANGO_LASER_PROJECTILE_TYPE
	)
	var minimum_remaining := 0.0 if view_bounded else 0.05
	var remaining := maxf(lifetime - compensation_age, minimum_remaining)
	if view_bounded and remaining <= 0.0:
		_release_projectile(projectile)
		return
	var bullet := projectile as Bullet
	if bullet != null:
		bullet.remaining_lifetime = remaining
		return
	if projectile is CollectibleArrowProjectile:
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
	var fire_sorcerer_volley := projectile as FireSorcererFireballVolley
	if fire_sorcerer_volley != null:
		fire_sorcerer_volley.remaining_lifetime = remaining
		return
	var fire_projectile := projectile as YuanshiInsectFireProjectile
	if fire_projectile != null:
		fire_projectile.remaining_lifetime = remaining
		return
	var frost_ice_spike := projectile as FrostSorcererIceSpike
	if frost_ice_spike != null:
		frost_ice_spike.remaining_lifetime = remaining
		return
	var projectile_script := projectile.get_script() as Script
	var projectile_script_path := (
		projectile_script.resource_path if projectile_script != null else ""
	)
	if projectile_script_path in [
		"res://scene/player/weishidaier/weishidaier_skill1_bomb.gd",
		"res://scene/boss/linglan/linglan_skill1_sakura_bullet.gd",
		"res://scene/boss/linglan/linglan_skill2_sakura_rocket.gd",
		"res://scene/boss/linglan/linglan_skill4_light_orb.gd",
	]:
		projectile.set("remaining_lifetime", remaining)


func _get_bounded_player_projectile_damage(
	owner_peer_id: int,
	reported_damage: int,
	projectile_type: StringName
) -> int:
	if reported_damage <= 0:
		return -1
	var owner_player := _get_player(owner_peer_id)
	if owner_player == null:
		return -1
	var damage_type := (
		EnemyConfig.DamageType.MAGIC
		if projectile_type == TIYI_SNIPER_PROJECTILE_TYPE
		else EnemyConfig.DamageType.PHYSICAL
	)
	var max_damage := owner_player.get_outgoing_damage(
		owner_player.attack_damage,
		damage_type
	)
	if projectile_type == &"skill1_bomb" and owner_player.has_skill1():
		max_damage = maxi(max_damage, owner_player.get_skill1_projectile_damage())
	return clampi(reported_damage, 1, max_damage)


func _get_frost_ice_spike_record(
	projectile_id: int,
	source_type: StringName
) -> Dictionary:
	if projectile_id <= 0 or source_type != FROST_SORCERER_ICE_SPIKE_TYPE:
		return {}
	var record := get_projectile_record(projectile_id)
	if (
		record.is_empty()
		or StringName(record.get("projectile_type", &""))
			!= FROST_SORCERER_ICE_SPIKE_TYPE
	):
		return {}
	return record


static func _is_fire_sorcerer_volley_type(projectile_type: StringName) -> bool:
	return (
		projectile_type == FIRE_SORCERER_FIREBALL_VOLLEY_TYPE
		or projectile_type == FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_TYPE
	)


static func _get_fire_sorcerer_projectile_type_for_source(
	source_type: StringName
) -> StringName:
	match source_type:
		&"fire_sorcerer_fireball_a", \
		&"fire_sorcerer_fireball_b", \
		&"fire_sorcerer_fireball_c":
			return FIRE_SORCERER_FIREBALL_VOLLEY_TYPE
		&"fire_sorcerer_elite_fireball_a", \
		&"fire_sorcerer_elite_fireball_b", \
		&"fire_sorcerer_elite_fireball_c":
			return FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_TYPE
		_:
			return &""


static func _get_fire_sorcerer_fireball_source_bit(
	source_type: StringName
) -> int:
	match source_type:
		&"fire_sorcerer_fireball_a", &"fire_sorcerer_elite_fireball_a":
			return 1
		&"fire_sorcerer_fireball_b", &"fire_sorcerer_elite_fireball_b":
			return 2
		&"fire_sorcerer_fireball_c", &"fire_sorcerer_elite_fireball_c":
			return 4
		_:
			return 0


func _consume_peer_rate_token(
	peer_id: int,
	now: float,
	rate_per_second: float,
	burst: float
) -> bool:
	if peer_id <= 0:
		return false
	var bucket := _client_projectile_request_rate_buckets.get(peer_id, {}) as Dictionary
	var tokens := float(bucket.get("tokens", burst))
	var last_time := float(bucket.get("last_time", now))
	if not is_finite(last_time):
		last_time = now
	tokens = minf(burst, tokens + maxf(now - last_time, 0.0) * rate_per_second)
	if tokens < 1.0:
		bucket["tokens"] = tokens
		bucket["last_time"] = now
		_client_projectile_request_rate_buckets[peer_id] = bucket
		return false
	bucket["tokens"] = tokens - 1.0
	bucket["last_time"] = now
	_client_projectile_request_rate_buckets[peer_id] = bucket
	return true


func _get_player(peer_id: int) -> Player:
	if not is_bound():
		return null
	var player := _runtime.get_player_for_peer(peer_id) as Player
	return player if player != null and is_instance_valid(player) else null


func _get_projectile_parent() -> Node:
	if not is_bound():
		return null
	var gateway := _runtime.get_multiplayer_gameplay_gateway()
	return gateway.get_projectile_parent() if gateway != null else null


func _release_projectile(projectile: Node) -> void:
	if projectile == null or not is_instance_valid(projectile):
		return
	if projectile.has_method("retire"):
		projectile.call("retire")
	elif is_bound() and _runtime.release_session_object(projectile):
		return
	else:
		projectile.queue_free()


func _on_network_projectile_finished(projectile_id: int, projectile: Node) -> void:
	_cancel_rejected_void_battery_prediction(projectile_id, projectile)
	if _known_projectiles.get(projectile_id) == projectile:
		_known_projectiles.erase(projectile_id)


func notify_projectile_finished(projectile_id: int, projectile: Node) -> void:
	_on_network_projectile_finished(projectile_id, projectile)


func _on_network_projectile_tree_exited(projectile_id: int, projectile: Node) -> void:
	_cancel_rejected_void_battery_prediction(projectile_id, projectile)
	if _known_projectiles.get(projectile_id) == projectile:
		_known_projectiles.erase(projectile_id)


func _cancel_rejected_void_battery_prediction(
	projectile_id: int,
	projectile: Node
) -> void:
	var record := get_projectile_record(projectile_id)
	if (
		record.is_empty()
		or bool(record.get("authority_confirmed", false))
		or StringName(record.get("projectile_type", &"")) != &"skill1_bomb"
	):
		return
	var owner_player := _get_player(int(record.get("owner_peer_id", 0)))
	if owner_player != null:
		owner_player.cancel_predicted_void_battery_activation(
			projectile.get_instance_id() if projectile != null else 0
		)


func notify_projectile_tree_exited(projectile_id: int, projectile: Node) -> void:
	_on_network_projectile_tree_exited(projectile_id, projectile)


func _clear_network_facade_dependencies() -> void:
	_net_manager = null
	_player_coordinator = null
	_get_net_time_callable = Callable()
	_get_host_event_age_callable = Callable()
	_is_embedded_participant_suspended_callable = Callable()


func _get_net_time() -> float:
	if not _get_net_time_callable.is_valid():
		return 0.0
	var now := float(_get_net_time_callable.call())
	return now if is_finite(now) else 0.0


func _get_host_event_age(host_event_timestamp: float) -> float:
	if host_event_timestamp < 0.0 or not _get_host_event_age_callable.is_valid():
		return 0.0
	var event_age := float(
		_get_host_event_age_callable.call(host_event_timestamp)
	)
	return maxf(event_age, 0.0) if is_finite(event_age) else 0.0


func _is_authority_sender(sender_id: int) -> bool:
	if not has_network_facade_dependencies():
		return false
	if sender_id <= 0:
		return _net_manager.is_host()
	return sender_id == _net_manager.get_host_peer_id()


static func _is_recent_event_cached(
	cache: Dictionary,
	key: Variant,
	now: float
) -> bool:
	return cache.has(key) and float(cache[key]) > now


static func _remember_recent_event(
	cache: Dictionary,
	key: Variant,
	retention_seconds: float,
	now: float
) -> void:
	cache[key] = now + retention_seconds


static func _is_finite_vector2(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y)
