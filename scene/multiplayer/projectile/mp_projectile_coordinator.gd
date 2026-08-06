extends Node
class_name MpProjectileCoordinator

signal rpc_to_host_requested(method_name: StringName, arguments: Array)
signal rpc_broadcast_requested(method_name: StringName, arguments: Array)

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")

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
const COMBAT_ROBOT_SUICIDE_DRONE_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone.tscn"
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
const FROST_SORCERER_ICE_SPIKE_TYPE: StringName = &"frost_sorcerer_ice_spike"
const COMBAT_ROBOT_SUICIDE_DRONE_TYPE: StringName = &"combat_robot_suicide_drone"
const TIYI_SNIPER_PROJECTILE_TYPE: StringName = &"tiyi_sniper_bullet"
const TANGO_LASER_PROJECTILE_TYPE: StringName = &"tango_laser_bullet"
const TANGO_LASER_VOLLEY_PROJECTILE_COUNT := 3
const LINGLAN_SKILL1_RING_MAX_PROJECTILES_PER_PACKET := 32
const CLIENT_PROJECTILE_SPAWN_POSITION_TOLERANCE := 224.0
const TANGO_NETWORK_BARRAGE_MAXIMUM_SECONDS := 5.0


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
	remember_projectile_record(
		projectile_id,
		owner_peer_id,
		projectile_type,
		damage,
		lifetime,
		pierces_enemies,
		now
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
			and not _projectile_records.has(projectile_id)
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
		if has_projectile(projectile_id) or has_projectile_record(projectile_id):
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
		if has_projectile(projectile_id) or has_projectile_record(projectile_id):
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


func get_projectile_time_compensation_age(
	unbounded_event_age: float,
	lifetime: float,
	projectile_type: StringName = &""
) -> float:
	if projectile_type == COMBAT_ROBOT_SUICIDE_DRONE_TYPE:
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


func clear_peer(peer_id: int) -> void:
	_client_projectile_request_rate_buckets.erase(peer_id)
	_last_tango_volley_visual_state_by_peer.erase(peer_id)
	clear_projectiles_for_peer(peer_id)
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
	_projectile_records.clear()
	_stale_projectile_record_ids.clear()
	_processed_enemy_hit_ids.clear()
	_client_projectile_request_rate_buckets.clear()
	_last_tango_volley_visual_state_by_peer.clear()
	_next_projectile_sequence = 1


func get_state_metrics() -> Dictionary:
	return {
		"next_sequence": _next_projectile_sequence,
		"known_projectiles": _known_projectiles.size(),
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
		&"combat_robot_gunner_bullet":
			var gunner_bullet := (
				_acquire_or_instantiate_projectile(
					COMBAT_ROBOT_GUNNER_BULLET_SCENE
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
		COMBAT_ROBOT_SUICIDE_DRONE_TYPE:
			if _runtime.combat_robot_drone_motion_system == null:
				return null
			var drone := (
				_acquire_or_instantiate_projectile(
					COMBAT_ROBOT_SUICIDE_DRONE_SCENE
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
			fireball.setup(direction, damage, speed, lifetime)
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
			if (
				not _is_valid_tiyi_player(owner_player)
				or not owner_player.can_request_multiplayer_projectile(projectile_type)
				or not owner_player.has_method("try_accept_authoritative_primary_shot")
				or not bool(owner_player.call(
					"try_accept_authoritative_primary_shot",
					projectile_type
				))
			):
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
					randf() < owner_player.get_inventory_bullet_pierce_chance()
				),
				"homes_to_enemy": (
					randf() < owner_player._get_inventory_bullet_homing_chance()
				),
			}
		&"skill1_bomb":
			if (
				not owner_player.can_request_multiplayer_projectile(projectile_type)
				or not owner_player.consume_multiplayer_skill1_charge()
			):
				return {}
			owner_player.activate_collectible_skill_effects_from_multiplayer()
			var bomb_scene := _get_runtime_packed_scene(SKILL1_BOMB_SCENE_PATH)
			if bomb_scene == null:
				return {}
			var bomb := bomb_scene.instantiate() as Node2D
			if bomb == null:
				return {}
			var result := {
				"damage": owner_player.get_skill1_projectile_damage(),
				"speed": float(bomb.get("speed")),
				"lifetime": float(bomb.get("max_lifetime")),
			}
			bomb.free()
			return result
		&"collectible_arrow":
			var arrow_damage := _get_authoritative_collectible_arrow_damage(
				owner_player
			)
			if arrow_damage <= 0:
				return {}
			var arrow := COLLECTIBLE_ARROW_PROJECTILE_SCENE.instantiate()
			if arrow == null:
				return {}
			var result := {
				"damage": arrow_damage,
				"speed": float(arrow.get("speed")),
				"lifetime": float(arrow.get("max_lifetime")),
			}
			arrow.free()
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
	reported_spawn_position: Vector2,
	accepted_direction: Vector2
) -> Vector2:
	if projectile_type != TIYI_SNIPER_PROJECTILE_TYPE:
		return reported_spawn_position
	var owner_player := _get_player(owner_peer_id)
	if not _is_valid_tiyi_player(owner_player) or accepted_direction == Vector2.ZERO:
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


func _get_authoritative_collectible_arrow_damage(owner_player: Player) -> int:
	if owner_player == null or not is_instance_valid(owner_player):
		return -1
	var active_items_variant: Variant = owner_player.call(
		"_get_active_collectible_items"
	)
	if not (active_items_variant is Array):
		return -1
	var best_damage := -1
	for item_variant in active_items_variant:
		var item := item_variant as PickupConfig
		if (
			item == null
			or item.periodic_effect_id != PickupConfig.PERIODIC_EFFECT_ARCHER
		):
			continue
		var damage_multiplier := maxf(
			item.periodic_attack_damage_multiplier,
			0.0
		)
		if damage_multiplier <= 0.0:
			damage_multiplier = 1.0
		var arrow_damage := owner_player.get_collectible_outgoing_damage(
			maxi(
				roundi(float(owner_player.attack_damage) * damage_multiplier),
				1
			),
			EnemyConfig.DamageType.PHYSICAL
		)
		best_damage = maxi(best_damage, arrow_damage)
	return best_damage


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
			or projectile_type == COMBAT_ROBOT_SUICIDE_DRONE_TYPE
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


func remember_projectile_record(
	projectile_id: int,
	owner_peer_id: int,
	projectile_type: StringName,
	damage: int,
	lifetime: float,
	pierces_enemies: bool,
	now: float
) -> void:
	if projectile_id <= 0:
		return
	var record := {
		"owner_peer_id": owner_peer_id,
		"projectile_type": projectile_type,
		"damage": maxi(damage, 0),
		"pierces_enemies": pierces_enemies,
		"confirmed_hit_consumed": false,
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
	if projectile_type == COMBAT_ROBOT_SUICIDE_DRONE_TYPE:
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
	if _known_projectiles.get(projectile_id) == projectile:
		_known_projectiles.erase(projectile_id)


func notify_projectile_finished(projectile_id: int, projectile: Node) -> void:
	_on_network_projectile_finished(projectile_id, projectile)


func _on_network_projectile_tree_exited(projectile_id: int, projectile: Node) -> void:
	if _known_projectiles.get(projectile_id) == projectile:
		_known_projectiles.erase(projectile_id)


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
