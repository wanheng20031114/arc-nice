@abstract
extends RuntimePreparationProvider
class_name CombatRuntimeBase

const CombatTargetIndexScript := preload("res://scene/combat/targeting/combat_target_index.gd")
const EnemySpawnEffectBudgetScript := preload("res://scene/combat/feedback/enemy_spawn_effect_budget.gd")
const EnemyCombatServicesScript := preload(
	"res://scene/combat/simulation/enemy_combat_services.gd"
)
const ENEMY_SPAWN_EFFECT_SCENE := preload(
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_spawn_effect.tscn"
)
const BULLET_HIT_EFFECT_POOL_SCENE := preload("res://scene/combat/projectiles/bullet_hit_effect.tscn")
const ENEMY_HIT_EFFECT_POOL_SCENE := preload("res://scene/enemy/enemy_hit_effect.tscn")
const MOVE_SPEED_TRAIL_EFFECT_POOL_SCENE := preload(
	"res://scene/combat/feedback/move_speed_trail_effect.tscn"
)
const CAPOO_MAGE_FIREBALL_IMPACT_POOL_SCENE := preload(
	"res://scene/enemy/capoo/capoo_mage_fireball_impact.tscn"
)
const COMBAT_ROBOT_GUNNER_BULLET_POOL_SCENE_PATH := (
	"res://scene/enemy/mechanical_life/combat_robot_gunner_bullet.tscn"
)
const COMBAT_ROBOT_GUNNER_ELITE_BULLET_POOL_SCENE_PATH := (
	"res://scene/enemy/mechanical_life/combat_robot_gunner_elite_bullet.tscn"
)
const LIGHTNING_SORCERER_LIGHTNING_VFX_POOL_SCENE := preload(
	"res://scene/enemy/sorcerer/lightning_sorcerer_lightning_vfx.tscn"
)
const ENEMY_SPAWN_EFFECT_PREWARM_COUNT := 16
const ENEMY_SPAWN_EFFECT_RETAINED_CAPACITY := 32
const BULLET_HIT_EFFECT_CAPACITY := 64
const ENEMY_HIT_EFFECT_CAPACITY := 128
const MOVE_SPEED_TRAIL_EFFECT_RETAINED_CAPACITY := 32
const LIGHTNING_SORCERER_LIGHTNING_VFX_PREWARM_COUNT := 64
const LIGHTNING_SORCERER_LIGHTNING_VFX_RETAINED_CAPACITY := 96
const COMBAT_ROBOT_GUNNER_BULLET_PREWARM_COUNT := 0
const COMBAT_ROBOT_GUNNER_BULLET_RETAINED_CAPACITY := 96
const COMBAT_ROBOT_GUNNER_ELITE_BULLET_PREWARM_COUNT := 0
const COMBAT_ROBOT_GUNNER_ELITE_BULLET_RETAINED_CAPACITY := 96
const SINGLEPLAYER_BULK_INDEX_MIN_TARGETS := 512

# The cohort probe overrides these before scene creation for isolated A/B runs.
# Production keeps the proven lazy 0/96 policy in both runtime modes.
static var combat_robot_gunner_bullet_pool_prewarm_count := (
	COMBAT_ROBOT_GUNNER_BULLET_PREWARM_COUNT
)
static var combat_robot_gunner_bullet_pool_retained_capacity := (
	COMBAT_ROBOT_GUNNER_BULLET_RETAINED_CAPACITY
)

enum RuntimeMode {
	SINGLEPLAYER,
	HOST_AUTHORITY,
	CLIENT_VIEW,
}

enum WorldLightingPolicy {
	FLOW_CONTROLLED,
	FIXED_DAY,
	FIXED_NIGHT,
}

## Player 投影结果区分“本次建立”和“此前已收敛”，让调用方只在 CREATED
## 时迁移一次附属状态；冲突与创建失败都保持可观察，不能退化成含糊的 null。
enum ReconnectedPlayerProjectionStatus {
	CREATED,
	EXISTING_CURRENT,
	CONFLICT,
	CREATE_FAILED,
	CAPTURE_STATE_INVALID,
	INGRESS_STATE_INVALID,
	INVALID_REQUEST,
}

class ReconnectedPlayerProjection:
	extends RefCounted

	var status: int
	var player: Player


	func _init(configured_status: int, configured_player: Player = null) -> void:
		status = configured_status
		player = configured_player


	func is_success() -> bool:
		return (
			status == ReconnectedPlayerProjectionStatus.CREATED
			or status == ReconnectedPlayerProjectionStatus.EXISTING_CURRENT
		) and (
			player != null
			and is_instance_valid(player)
			and not player.is_queued_for_deletion()
		)

@export var runtime_mode: RuntimeMode = RuntimeMode.SINGLEPLAYER

@export_group("世界光照")
@export var world_lighting_policy: WorldLightingPolicy = (
	WorldLightingPolicy.FLOW_CONTROLLED
)

@onready var enemy_container: Node2D = $EnemyContainer
@onready var grid_pathfinder: Node = $GridPathfinder
@onready var capoo_projectile_motion_system: Node = $CapooProjectileMotionSystem
@onready var combat_robot_drone_motion_system: CombatRobotDroneMotionSystem = (
	$CombatRobotDroneMotionSystem
)
@onready var day_night_controller: DayNightController = $DayNightController
@onready var multiplayer_gateway: MultiplayerGameplayGateway = (
	$MultiplayerGameplayGateway
)
@onready var multiplayer_mode_adapter: MultiplayerModeAdapter = (
	$MultiplayerModeAdapter
)

var player: Player = null
var multiplayer_local_peer_id: int = 0
var peer_players: Dictionary = {}
var _network_pickup_net_id_by_instance_id: Dictionary[int, int] = {}
var _network_pickup_by_net_id: Dictionary[int, Pickup] = {}
## Network enemy identity has one owner: the combat runtime. Callers must use the
## atomic registry API below so net-id, instance-id and CombatTargetIndex cannot
## drift apart during replacement, terminal events or session teardown.
var _network_enemy_net_id_by_instance_id: Dictionary[int, int] = {}
var _network_enemy_by_net_id: Dictionary[int, Enemy] = {}
var combat_target_index = CombatTargetIndexScript.new()
## Relation policy and the cross-store query facade are runtime-owned so every
## enemy, coordinator and multiplayer projection observes the same live rules.
var combat_relation_service: CombatRelationService = CombatRelationService.new()
var combat_query_facade: CombatQueryFacade = null
var _enemy_combat_services: EnemyCombatServicesScript = null
## Shared storage for secondary enemy-attack queries. Lightning chains and
## homing projectiles execute on the authoritative physics thread, so one
## runtime-owned buffer avoids allocating an Array for every bounce/reacquire.
var _enemy_attack_target_query_scratch: Array[Node2D] = []
var _singleplayer_combat_target_index_enabled := false
var _singleplayer_combat_target_index_force_local_queries := false
var _enemy_snapshot_states_by_net_id: Dictionary = {}
var _enemy_snapshot_output: Array[SnapshotManager.EnemyState] = []
var _enemy_snapshot_live_ids: Dictionary = {}
var _stale_enemy_snapshot_ids: Array[int] = []
var _enemy_spawn_effect_budget = EnemySpawnEffectBudgetScript.new()
var runtime_activation_deferred := false
var runtime_activated := false
var _scene_teardown_prepared := false
var _pending_xirang_kill_reward: int = 0
var _xirang_kill_reward_flush_queued: bool = false
var player_persistent_modifier_projector: PlayerPersistentModifierProjector = null


func get_multiplayer_gameplay_gateway() -> MultiplayerGameplayGateway:
	var gateway := multiplayer_gateway
	if gateway == null:
		gateway = get_node_or_null(
			"MultiplayerGameplayGateway"
		) as MultiplayerGameplayGateway
	if gateway != null and gateway.runtime != self:
		gateway.bind_runtime(self)
	return gateway


func get_enemy_simulation_coordinator() -> EnemySimulationCoordinator:
	return get_node_or_null(
		"EnemySimulationCoordinator"
	) as EnemySimulationCoordinator


func get_enemy_combat_services() -> EnemyCombatServicesScript:
	if (
		_enemy_combat_services != null
		and is_instance_valid(_enemy_combat_services)
	):
		var cached_coordinator := get_enemy_simulation_coordinator()
		if (
			cached_coordinator != null
			and _enemy_combat_services.is_bound_to(self, cached_coordinator)
		):
			return _enemy_combat_services
	_enemy_combat_services = null
	var coordinator := get_enemy_simulation_coordinator()
	if coordinator == null:
		return null
	var combat_services := coordinator.get_combat_services()
	if (
		combat_services == null
		or not combat_services.bind_context(self, coordinator)
	):
		return null
	_enemy_combat_services = combat_services
	return _enemy_combat_services


func cache_enemy_combat_services(
	combat_services: EnemyCombatServicesScript
) -> bool:
	if (
		_scene_teardown_prepared
		or combat_services == null
		or not is_instance_valid(combat_services)
	):
		return false
	var coordinator := get_enemy_simulation_coordinator()
	if (
		coordinator == null
		or combat_services.get_parent() != coordinator
		or coordinator.get_parent() != self
	):
		return false
	if (
		_enemy_combat_services != null
		and is_instance_valid(_enemy_combat_services)
		and _enemy_combat_services != combat_services
	):
		return false
	_enemy_combat_services = combat_services
	return true


func get_enemy_contact_service() -> EnemyContactService:
	return get_node_or_null("EnemyContactService") as EnemyContactService


func get_combat_relation_service() -> CombatRelationService:
	return combat_relation_service


## Reward/drop settlement is deliberately downstream of the synchronous
## `Enemy.defeated` domain signal. Runtimes owning a terminal ledger override
## this and only approve a committed DEFEATED record; sandbox runtimes without
## a ledger preserve their historical immediate settlement.
func can_settle_enemy_defeat_rewards(_enemy_id: int) -> bool:
	return true


func get_combat_query_facade() -> CombatQueryFacade:
	if combat_query_facade == null:
		combat_query_facade = CombatQueryFacade.new(self)
	else:
		combat_query_facade.bind_runtime(self)
	return combat_query_facade


func get_multiplayer_mode_adapter() -> MultiplayerModeAdapter:
	var adapter := multiplayer_mode_adapter
	if adapter == null:
		adapter = get_node_or_null(
			"MultiplayerModeAdapter"
		) as MultiplayerModeAdapter
	if adapter != null and adapter.runtime != self:
		adapter.bind_runtime(self)
	return adapter


func bind_player_runtime_context(player_instance: Player) -> void:
	if player_instance != null:
		player_instance.bind_combat_runtime(self)


func configure_player_persistent_modifier_projector(
	projector: PlayerPersistentModifierProjector
) -> void:
	player_persistent_modifier_projector = projector


func bind_enemy_runtime_context(enemy_instance: Enemy) -> void:
	if enemy_instance != null:
		enemy_instance.bind_combat_runtime(self)


func transition_world_to_night(duration_seconds: float = -1.0) -> void:
	_request_world_lighting(true, duration_seconds)


func transition_world_to_day(duration_seconds: float = -1.0) -> void:
	_request_world_lighting(false, duration_seconds)


func initialize_world_lighting() -> void:
	var initial_night_factor := (
		1.0
		if world_lighting_policy == WorldLightingPolicy.FIXED_NIGHT
		else 0.0
	)
	_set_fixed_world_lighting(initial_night_factor)


func _request_world_lighting(
	request_night: bool,
	duration_seconds: float
) -> void:
	match world_lighting_policy:
		WorldLightingPolicy.FIXED_DAY:
			_set_fixed_world_lighting(0.0)
		WorldLightingPolicy.FIXED_NIGHT:
			_set_fixed_world_lighting(1.0)
		_:
			if request_night:
				day_night_controller.transition_to_night(duration_seconds)
			else:
				day_night_controller.transition_to_day(duration_seconds)


func _set_fixed_world_lighting(night_factor: float) -> void:
	var safe_factor := clampf(night_factor, 0.0, 1.0)
	if (
		not day_night_controller.is_transitioning()
		and is_equal_approx(day_night_controller.night_factor, safe_factor)
	):
		return
	day_night_controller.set_night_factor_immediate(safe_factor)


@abstract func configure_multiplayer(
	mode: int,
	local_peer_id: int,
	player_names: Dictionary,
	player_character_ids: Dictionary = {}
) -> void


@abstract func get_player_for_peer(peer_id: int) -> Player
@abstract func get_enemy_for_net_id(net_id: int) -> Enemy
@abstract func get_pickup_for_net_id(net_id: int) -> Pickup
@abstract func remove_multiplayer_player(peer_id: int) -> void
## 身份账本提交后，用同一个强类型入口确保 new peer 的场景投影存在。
## 客户端 setup 可能已经创建该节点，实现必须幂等复用并重新校准，而不是
## 把“已经存在”误判成恢复失败；失败必须用明确状态返回，不能用 null 混淆。
func ensure_reconnected_multiplayer_player(
	_old_peer_id: int,
	_new_peer_id: int,
	_player_name: String,
	_character_id: StringName,
	_state: SnapshotManager.PlayerState,
	_spawn_slot_index: int,
	_reconnect_state: Dictionary = {}
) -> ReconnectedPlayerProjection:
	# 纯测试/辅助运行时可以明确声明不支持重连投影；正式多人模式必须覆写。
	return ReconnectedPlayerProjection.new(
		ReconnectedPlayerProjectionStatus.INVALID_REQUEST
	)
@abstract func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]
@abstract func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]
@abstract func play_remote_enemy_spawn_effect(spawn_global_position: Vector2) -> void


static func register_common_visual_effect_pools(pool: SessionObjectPool) -> void:
	# Enemy speed trails are exceptional status VFX. Keep no idle GPU particle
	# nodes at startup; active hasted enemies lease them elastically and overflow
	# instances are discarded again instead of becoming permanent horde baggage.
	pool.register_scene(
		MOVE_SPEED_TRAIL_EFFECT_POOL_SCENE,
		0,
		MOVE_SPEED_TRAIL_EFFECT_RETAINED_CAPACITY
	)
	pool.register_scene(
		ENEMY_SPAWN_EFFECT_SCENE,
		ENEMY_SPAWN_EFFECT_PREWARM_COUNT,
		ENEMY_SPAWN_EFFECT_RETAINED_CAPACITY
	)
	pool.register_scene(
		BULLET_HIT_EFFECT_POOL_SCENE,
		BULLET_HIT_EFFECT_CAPACITY,
		BULLET_HIT_EFFECT_CAPACITY
	)
	pool.register_scene(
		ENEMY_HIT_EFFECT_POOL_SCENE,
		ENEMY_HIT_EFFECT_CAPACITY,
		ENEMY_HIT_EFFECT_CAPACITY
	)
	# Chain lightning is optional feedback, never gameplay authority. A strict
	# 96-lease ceiling bounds draw work during synchronized sorcerer volleys.
	pool.register_scene(
		LIGHTNING_SORCERER_LIGHTNING_VFX_POOL_SCENE,
		LIGHTNING_SORCERER_LIGHTNING_VFX_PREWARM_COUNT,
		LIGHTNING_SORCERER_LIGHTNING_VFX_RETAINED_CAPACITY
	)


static func register_combat_robot_gunner_bullet_pool(
	pool: SessionObjectPool,
	prewarm_count: int = -1,
	retained_capacity: int = -1
) -> void:
	if pool == null:
		return
	# Runtime loading avoids a compile-time cycle: the projectile inherits shared
	# enemy code that resolves CombatRuntimeBase while this base script is loading.
	var projectile_scene := load(
		COMBAT_ROBOT_GUNNER_BULLET_POOL_SCENE_PATH
	) as PackedScene
	if projectile_scene == null:
		push_error("无法加载持枪战斗机器人弹丸池场景。")
		return
	var resolved_prewarm_count := (
		combat_robot_gunner_bullet_pool_prewarm_count
		if prewarm_count < 0
		else prewarm_count
	)
	var resolved_retained_capacity := (
		combat_robot_gunner_bullet_pool_retained_capacity
		if retained_capacity < 0
		else retained_capacity
	)
	pool.register_scene(
		projectile_scene,
		maxi(resolved_prewarm_count, 0),
		maxi(resolved_retained_capacity, 1)
	)


static func register_combat_robot_gunner_elite_bullet_pool(
	pool: SessionObjectPool,
	prewarm_count: int = COMBAT_ROBOT_GUNNER_ELITE_BULLET_PREWARM_COUNT,
	retained_capacity: int = COMBAT_ROBOT_GUNNER_ELITE_BULLET_RETAINED_CAPACITY
) -> void:
	if pool == null:
		return
	var projectile_scene := load(
		COMBAT_ROBOT_GUNNER_ELITE_BULLET_POOL_SCENE_PATH
	) as PackedScene
	if projectile_scene == null:
		push_error("无法加载精英持枪战斗机器人弹丸池场景。")
		return
	pool.register_scene(
		projectile_scene,
		maxi(prewarm_count, 0),
		maxi(retained_capacity, 1)
	)


## Shared singleplayer/host/client visual entry point. Multiplayer packets and
## authoritative enemies pass the same compact world-space chain path here.
func play_lightning_sorcerer_chain_vfx(world_path: PackedVector2Array) -> bool:
	return LightningSorcererLightningVfx.try_spawn(self, world_path)


static func register_capoo_mage_fireball_impact_pool(
	pool: SessionObjectPool,
	prewarm_count: int,
	retained_capacity: int
) -> void:
	if pool == null:
		return
	pool.register_scene(
		CAPOO_MAGE_FIREBALL_IMPACT_POOL_SCENE,
		maxi(prewarm_count, 0),
		maxi(retained_capacity, 1)
	)


func try_reserve_enemy_spawn_effect(
	spawn_global_position: Vector2,
	sample_time_seconds: float = -1.0
) -> bool:
	return _enemy_spawn_effect_budget.try_reserve(
		self,
		spawn_global_position,
		sample_time_seconds
	)


func register_combat_target(net_id: int, enemy: Enemy) -> void:
	combat_target_index.register_enemy(net_id, enemy)


func unregister_combat_target(net_id: int) -> void:
	combat_target_index.unregister_enemy(net_id)


func register_network_enemy(net_id: int, enemy: Enemy) -> bool:
	if (
		_scene_teardown_prepared
		or net_id <= 0
		or enemy == null
		or not is_instance_valid(enemy)
	):
		return false
	var instance_id := enemy.get_instance_id()
	var previous_net_id := int(
		_network_enemy_net_id_by_instance_id.get(instance_id, 0)
	)
	if previous_net_id > 0 and previous_net_id != net_id:
		unregister_network_enemy(previous_net_id, enemy)
	var previous_enemy := _get_valid_network_enemy_entry(net_id)
	if _network_enemy_by_net_id.has(net_id):
		if previous_enemy == null or not is_instance_valid(previous_enemy):
			unregister_network_enemy(net_id)
		elif previous_enemy != enemy:
			unregister_network_enemy(net_id, previous_enemy)
	enemy.set_meta(&"net_id", net_id)
	_network_enemy_by_net_id[net_id] = enemy
	_network_enemy_net_id_by_instance_id[instance_id] = net_id
	register_combat_target(net_id, enemy)
	return true


func unregister_network_enemy(
	net_id: int,
	expected_enemy: Enemy = null
) -> Enemy:
	if net_id <= 0:
		return null
	var registered_enemy := _get_valid_network_enemy_entry(net_id)
	if (
		expected_enemy != null
		and is_instance_valid(expected_enemy)
		and registered_enemy != expected_enemy
	):
		if registered_enemy == null:
			var expected_instance_id := expected_enemy.get_instance_id()
			if int(_network_enemy_net_id_by_instance_id.get(
				expected_instance_id,
				0
			)) == net_id:
				_network_enemy_net_id_by_instance_id.erase(expected_instance_id)
			_network_enemy_by_net_id.erase(net_id)
			unregister_combat_target(net_id)
		return null
	_network_enemy_by_net_id.erase(net_id)
	unregister_combat_target(net_id)
	if registered_enemy != null and is_instance_valid(registered_enemy):
		var instance_id := registered_enemy.get_instance_id()
		if int(_network_enemy_net_id_by_instance_id.get(instance_id, 0)) == net_id:
			_network_enemy_net_id_by_instance_id.erase(instance_id)
	else:
		_erase_network_enemy_reverse_mappings(net_id)
	return registered_enemy


func unregister_network_enemy_by_instance_id(instance_id: int) -> int:
	if instance_id <= 0:
		return 0
	var net_id := int(_network_enemy_net_id_by_instance_id.get(instance_id, 0))
	if net_id <= 0:
		return 0
	var enemy := _get_valid_network_enemy_entry(net_id)
	if enemy != null and is_instance_valid(enemy) and enemy.get_instance_id() != instance_id:
		_network_enemy_net_id_by_instance_id.erase(instance_id)
		return 0
	unregister_network_enemy(net_id, enemy)
	return net_id


func get_network_enemy(net_id: int) -> Enemy:
	if net_id <= 0:
		return null
	var enemy := _get_valid_network_enemy_entry(net_id)
	if enemy == null:
		unregister_network_enemy(net_id)
		return null
	var instance_id := enemy.get_instance_id()
	if int(_network_enemy_net_id_by_instance_id.get(instance_id, 0)) != net_id:
		# An inconsistent entry is not returned as valid gameplay state. Repair the
		# exact pair rather than allowing two identity truths to survive.
		unregister_network_enemy(net_id, enemy)
		return null
	return enemy


func get_network_enemy_net_id_by_instance_id(instance_id: int) -> int:
	if instance_id <= 0:
		return 0
	var net_id := int(_network_enemy_net_id_by_instance_id.get(instance_id, 0))
	if net_id <= 0:
		return 0
	var enemy := _get_valid_network_enemy_entry(net_id)
	if enemy == null or enemy.get_instance_id() != instance_id:
		_network_enemy_net_id_by_instance_id.erase(instance_id)
		return 0
	return net_id


func has_network_enemy(net_id: int) -> bool:
	return get_network_enemy(net_id) != null


func get_network_enemy_count() -> int:
	return get_network_enemies().size()


func get_network_enemy_ids() -> Array[int]:
	var result: Array[int] = []
	for net_id_variant in _network_enemy_by_net_id:
		result.append(int(net_id_variant))
	return result


func get_network_enemies() -> Array[Enemy]:
	var result: Array[Enemy] = []
	for net_id in get_network_enemy_ids():
		var enemy := get_network_enemy(net_id)
		if enemy != null:
			result.append(enemy)
	return result


func clear_network_enemy_registry() -> void:
	for net_id in get_network_enemy_ids():
		unregister_network_enemy(net_id)
	_network_enemy_by_net_id.clear()
	_network_enemy_net_id_by_instance_id.clear()


func _erase_network_enemy_reverse_mappings(net_id: int) -> void:
	var stale_instance_ids: Array[int] = []
	for instance_id_variant in _network_enemy_net_id_by_instance_id:
		if int(_network_enemy_net_id_by_instance_id[instance_id_variant]) == net_id:
			stale_instance_ids.append(int(instance_id_variant))
	for instance_id in stale_instance_ids:
		_network_enemy_net_id_by_instance_id.erase(instance_id)


func _get_valid_network_enemy_entry(net_id: int) -> Enemy:
	var enemy_variant: Variant = _network_enemy_by_net_id.get(net_id)
	if enemy_variant == null or not is_instance_valid(enemy_variant):
		return null
	return enemy_variant as Enemy


func register_network_pickup(net_id: int, pickup: Pickup) -> bool:
	if (
		_scene_teardown_prepared
		or net_id <= 0
		or pickup == null
		or not is_instance_valid(pickup)
	):
		return false
	var instance_id := pickup.get_instance_id()
	var previous_net_id := int(
		_network_pickup_net_id_by_instance_id.get(instance_id, 0)
	)
	if previous_net_id > 0 and previous_net_id != net_id:
		unregister_network_pickup(previous_net_id, pickup)
	var previous_pickup := _get_valid_network_pickup_entry(net_id)
	if _network_pickup_by_net_id.has(net_id):
		if previous_pickup == null:
			unregister_network_pickup(net_id)
		elif previous_pickup != pickup:
			unregister_network_pickup(net_id, previous_pickup)
	pickup.set_meta(&"net_id", net_id)
	_network_pickup_by_net_id[net_id] = pickup
	_network_pickup_net_id_by_instance_id[instance_id] = net_id
	return true


func unregister_network_pickup(
	net_id: int,
	expected_pickup: Pickup = null
) -> Pickup:
	if net_id <= 0:
		return null
	var registered_pickup := _get_valid_network_pickup_entry(net_id)
	if (
		expected_pickup != null
		and is_instance_valid(expected_pickup)
		and registered_pickup != expected_pickup
	):
		if registered_pickup == null:
			var expected_instance_id := expected_pickup.get_instance_id()
			if int(_network_pickup_net_id_by_instance_id.get(
				expected_instance_id,
				0
			)) == net_id:
				_network_pickup_net_id_by_instance_id.erase(expected_instance_id)
			_network_pickup_by_net_id.erase(net_id)
		return null
	_network_pickup_by_net_id.erase(net_id)
	if registered_pickup != null and is_instance_valid(registered_pickup):
		var instance_id := registered_pickup.get_instance_id()
		if int(_network_pickup_net_id_by_instance_id.get(instance_id, 0)) == net_id:
			_network_pickup_net_id_by_instance_id.erase(instance_id)
	else:
		_erase_network_pickup_reverse_mappings(net_id)
	return registered_pickup


func unregister_network_pickup_by_instance_id(instance_id: int) -> int:
	if instance_id <= 0:
		return 0
	var net_id := int(_network_pickup_net_id_by_instance_id.get(instance_id, 0))
	if net_id <= 0:
		return 0
	var pickup := _get_valid_network_pickup_entry(net_id)
	if (
		pickup != null
		and pickup.get_instance_id() != instance_id
	):
		_network_pickup_net_id_by_instance_id.erase(instance_id)
		return 0
	unregister_network_pickup(net_id, pickup)
	return net_id


func get_network_pickup(net_id: int) -> Pickup:
	if net_id <= 0:
		return null
	var pickup := _get_valid_network_pickup_entry(net_id)
	if pickup == null:
		_network_pickup_by_net_id.erase(net_id)
		_erase_network_pickup_reverse_mappings(net_id)
		return null
	var instance_id := pickup.get_instance_id()
	if int(_network_pickup_net_id_by_instance_id.get(instance_id, 0)) != net_id:
		unregister_network_pickup(net_id, pickup)
		return null
	return pickup


func get_network_pickup_net_id_by_instance_id(instance_id: int) -> int:
	if instance_id <= 0:
		return 0
	var net_id := int(_network_pickup_net_id_by_instance_id.get(instance_id, 0))
	if net_id <= 0:
		return 0
	var pickup := _get_valid_network_pickup_entry(net_id)
	if pickup == null or pickup.get_instance_id() != instance_id:
		_network_pickup_net_id_by_instance_id.erase(instance_id)
		return 0
	return net_id


func has_network_pickup(net_id: int) -> bool:
	return get_network_pickup(net_id) != null


func get_network_pickup_count() -> int:
	var live_count := 0
	for net_id in get_network_pickup_ids():
		if get_network_pickup(net_id) != null:
			live_count += 1
	return live_count


func get_network_pickup_ids() -> Array[int]:
	var result: Array[int] = []
	for net_id_variant in _network_pickup_by_net_id:
		result.append(int(net_id_variant))
	return result


func clear_network_pickup_registry() -> void:
	_network_pickup_by_net_id.clear()
	_network_pickup_net_id_by_instance_id.clear()


func _get_valid_network_pickup_entry(net_id: int) -> Pickup:
	var pickup_variant: Variant = _network_pickup_by_net_id.get(net_id)
	if pickup_variant == null or not is_instance_valid(pickup_variant):
		return null
	return pickup_variant as Pickup


func _erase_network_pickup_reverse_mappings(net_id: int) -> void:
	var stale_instance_ids: Array[int] = []
	for instance_id_variant in _network_pickup_net_id_by_instance_id:
		if int(_network_pickup_net_id_by_instance_id[instance_id_variant]) == net_id:
			stale_instance_ids.append(int(instance_id_variant))
	for instance_id in stale_instance_ids:
		_network_pickup_net_id_by_instance_id.erase(instance_id)


func find_nearest_enemy_attack_target_world(
	from_position: Vector2,
	max_distance: float,
	excluded_instance_ids: Dictionary = {}
) -> Node2D:
	if max_distance < 0.0 or not is_finite(max_distance):
		return null
	var maximum_distance_squared := max_distance * max_distance
	var nearest_player: Player = null
	var nearest_distance_squared := maximum_distance_squared
	var nearest_instance_id := 0
	if (
		player != null
		and is_instance_valid(player)
		and not player.is_dead
		and not player.is_queued_for_deletion()
		and not excluded_instance_ids.has(player.get_instance_id())
	):
		var player_distance_squared := from_position.distance_squared_to(
			player.global_position
		)
		if player_distance_squared <= maximum_distance_squared:
			nearest_player = player
			nearest_distance_squared = player_distance_squared
			nearest_instance_id = int(player.get_instance_id())
	for peer_id_variant in peer_players:
		var candidate := peer_players[peer_id_variant] as Player
		if (
			candidate == null
			or candidate == player
			or not is_instance_valid(candidate)
			or candidate.is_dead
			or candidate.is_queued_for_deletion()
			or excluded_instance_ids.has(candidate.get_instance_id())
		):
			continue
		var distance_squared := from_position.distance_squared_to(
			candidate.global_position
		)
		if distance_squared > maximum_distance_squared:
			continue
		var instance_id := int(candidate.get_instance_id())
		if (
			nearest_player == null
			or distance_squared < nearest_distance_squared
			or (
				distance_squared == nearest_distance_squared
				and instance_id < nearest_instance_id
			)
		):
			nearest_player = candidate
			nearest_distance_squared = distance_squared
			nearest_instance_id = instance_id
	return nearest_player


## Faction-aware successor to the legacy Player/Plant-only attack query. The
## query facade preserves the independent player, plant and enemy stores, then
## orders their combined candidates by distance, target kind and stable ID.
## Callers pass the faction frozen into their attack/projectile snapshot; target
## factions are deliberately read live by CombatQueryFacade on every query.
func find_nearest_hostile_enemy_attack_target_world(
	from_position: Vector2,
	max_distance: float,
	source_faction_id: int,
	excluded_instance_ids: Dictionary = {}
) -> Node2D:
	_enemy_attack_target_query_scratch.clear()
	if (
		not from_position.is_finite()
		or not is_finite(max_distance)
		or max_distance < 0.0
		or not CombatRelationService.is_valid_faction_id(source_faction_id)
	):
		return null
	get_combat_query_facade().query_hostile_radius_into(
		from_position,
		max_distance,
		source_faction_id,
		_enemy_attack_target_query_scratch,
		null,
		0,
		combat_relation_service
	)
	for candidate in _enemy_attack_target_query_scratch:
		if excluded_instance_ids.has(candidate.get_instance_id()):
			continue
		return candidate
	return null


## Fills caller-owned storage with the deterministic hostile attack-target
## candidates for one world-space radius. Chain attacks can enumerate this
## broad candidate set around several hop centers without allocating or
## repeating the player/plant/enemy store query for every hop.
func query_hostile_enemy_attack_targets_world_into(
	from_position: Vector2,
	max_distance: float,
	source_faction_id: int,
	result: Array[Node2D],
	excluded_target: Node2D = null,
	max_count: int = 0
) -> void:
	get_combat_query_facade().query_hostile_radius_into(
		from_position,
		max_distance,
		source_faction_id,
		result,
		excluded_target,
		max_count,
		combat_relation_service
	)


## Fills caller-owned storage with every living allied player in an exact
## world-space circle. Plant auras use this facade in both solo and Host modes
## without rebuilding the scene tree or allocating a temporary player list.
func query_living_players_into(result: Array[Player]) -> void:
	result.clear()
	if (
		player != null
		and is_instance_valid(player)
		and not player.is_dead
		and not player.is_queued_for_deletion()
	):
		result.append(player)
	for peer_id_variant in peer_players:
		var candidate := peer_players[peer_id_variant] as Player
		if (
			candidate == null
			or candidate == player
			or not is_instance_valid(candidate)
			or candidate.is_dead
			or candidate.is_queued_for_deletion()
		):
			continue
		result.append(candidate)


func query_living_players_in_radius_into(
	center: Vector2,
	radius: float,
	result: Array[Player]
) -> void:
	result.clear()
	if not center.is_finite() or not is_finite(radius) or radius < 0.0:
		return
	var radius_squared := radius * radius
	if (
		player != null
		and is_instance_valid(player)
		and not player.is_dead
		and not player.is_queued_for_deletion()
		and center.distance_squared_to(player.global_position) <= radius_squared
	):
		result.append(player)
	for peer_id_variant in peer_players:
		var candidate := peer_players[peer_id_variant] as Player
		if (
			candidate == null
			or candidate == player
			or not is_instance_valid(candidate)
			or candidate.is_dead
			or candidate.is_queued_for_deletion()
			or center.distance_squared_to(candidate.global_position) > radius_squared
		):
			continue
		result.append(candidate)


## Single-player and Host-authoritative runtimes share one explicit plant-aura
## healing gateway. Multiplayer replication wraps this method in MpGame.
func apply_authoritative_player_heal(
	target_player: Player,
	heal_amount: int
) -> bool:
	if (
		runtime_mode == RuntimeMode.CLIENT_VIEW
		or target_player == null
		or not is_instance_valid(target_player)
		or heal_amount <= 0
	):
		return false
	return target_player._try_heal(heal_amount)


func enable_singleplayer_combat_target_index(force_local_queries: bool = false) -> void:
	if runtime_mode != RuntimeMode.SINGLEPLAYER:
		return
	_singleplayer_combat_target_index_enabled = true
	_singleplayer_combat_target_index_force_local_queries = (
		_singleplayer_combat_target_index_force_local_queries or force_local_queries
	)
	var target_containers: Array[Node] = [
		enemy_container,
		get_node_or_null("BossContainer"),
	]
	for target_container in target_containers:
		if target_container == null:
			continue
		if not target_container.child_entered_tree.is_connected(
			_on_singleplayer_combat_target_entered
		):
			target_container.child_entered_tree.connect(
				_on_singleplayer_combat_target_entered
			)
		if not target_container.child_exiting_tree.is_connected(
			_on_singleplayer_combat_target_exiting
		):
			target_container.child_exiting_tree.connect(
				_on_singleplayer_combat_target_exiting
			)
		for child in target_container.get_children():
			_on_singleplayer_combat_target_entered(child)


func _on_singleplayer_combat_target_entered(child: Node) -> void:
	if runtime_mode != RuntimeMode.SINGLEPLAYER:
		return
	var enemy := child as Enemy
	if enemy == null:
		return
	register_combat_target(enemy.get_instance_id(), enemy)


func _on_singleplayer_combat_target_exiting(child: Node) -> void:
	if runtime_mode != RuntimeMode.SINGLEPLAYER:
		return
	var enemy := child as Enemy
	if enemy == null:
		return
	unregister_combat_target(enemy.get_instance_id())


func get_all_combat_targets() -> Array[Enemy]:
	# A global result still has to visit and return every enemy. Direct container
	# iteration avoids bucket/dictionary indirection that cannot prune this O(n)
	# result; local-radius consumers use the maintained index below.
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		var result: Array[Enemy] = []
		_collect_combat_targets_from_container(enemy_container, result)
		_collect_combat_targets_from_container(get_node_or_null("BossContainer"), result)
		return result
	return combat_target_index.get_all_alive()


func pick_random_combat_target(center: Vector2, radius: float = 0.0) -> Enemy:
	if runtime_mode != RuntimeMode.SINGLEPLAYER or _singleplayer_combat_target_index_enabled:
		return combat_target_index.pick_random_alive_in_radius(center, radius)
	# Lightweight fixtures and an early pre-activation call can precede index
	# enablement. Preserve behavior there without weakening the indexed production
	# path used by every production combat runtime.
	var safe_radius := maxf(radius, 0.0)
	var radius_squared := safe_radius * safe_radius
	var selected_enemy: Enemy = null
	var candidate_count := 0
	var target_containers: Array[Node] = [
		enemy_container,
		get_node_or_null("BossContainer"),
	]
	for target_container in target_containers:
		if target_container == null:
			continue
		for child in target_container.get_children():
			var enemy := child as Enemy
			if not CombatTargetIndexScript.is_enemy_queryable(enemy):
				continue
			if (
				safe_radius > 0.0
				and center.distance_squared_to(enemy.global_position) > radius_squared
			):
				continue
			candidate_count += 1
			if randi() % candidate_count == 0:
				selected_enemy = enemy
	return selected_enemy


## Allocation-free nearest-enemy facade for instantaneous player-side chains.
## Local instance IDs are appropriate only for one authoritative traversal;
## cross-frame or network state must keep using stable enemy net IDs.
func find_nearest_combat_target(
	center: Vector2,
	radius: float,
	excluded_instance_ids: Dictionary = {}
) -> Enemy:
	if not center.is_finite() or not is_finite(radius) or radius < 0.0:
		return null
	if (
		runtime_mode != RuntimeMode.SINGLEPLAYER
		or (_singleplayer_combat_target_index_enabled and radius > 0.0)
	):
		return combat_target_index.find_nearest_alive_excluding(
			center,
			radius,
			excluded_instance_ids
		)
	var radius_squared := radius * radius
	var nearest := _find_nearest_combat_target_in_container(
		enemy_container,
		center,
		radius_squared,
		excluded_instance_ids,
		null
	)
	return _find_nearest_combat_target_in_container(
		get_node_or_null("BossContainer"),
		center,
		radius_squared,
		excluded_instance_ids,
		nearest
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
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		if _should_use_singleplayer_combat_target_index(radius, max_count):
			combat_target_index.query_radius_into(center, radius, result, max_count)
			return
		var safe_radius := maxf(radius, 0.0)
		var radius_squared := safe_radius * safe_radius
		_append_combat_targets_in_radius(enemy_container, center, safe_radius, radius_squared, result)
		_append_combat_targets_in_radius(
			get_node_or_null("BossContainer"),
			center,
			safe_radius,
			radius_squared,
			result
		)
		if max_count == 1:
			_retain_nearest_combat_target(result, center)
			return
		result.sort_custom(
			func(a: Enemy, b: Enemy) -> bool:
				var a_distance := center.distance_squared_to(a.global_position)
				var b_distance := center.distance_squared_to(b.global_position)
				if a_distance != b_distance:
					return a_distance < b_distance
				return a.get_instance_id() < b.get_instance_id()
		)
		if max_count > 0 and result.size() > max_count:
			result.resize(max_count)
		return
	combat_target_index.query_radius_into(center, radius, result, max_count)


func query_combat_targets_unordered_into(
	center: Vector2,
	radius: float,
	result: Array[Enemy]
) -> void:
	result.clear()
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		if _should_use_singleplayer_combat_target_index(radius, 1, true):
			combat_target_index.query_radius_unordered_into(center, radius, result)
			return
		var safe_radius := maxf(radius, 0.0)
		var radius_squared := safe_radius * safe_radius
		_append_combat_targets_in_radius(
			enemy_container,
			center,
			safe_radius,
			radius_squared,
			result
		)
		_append_combat_targets_in_radius(
			get_node_or_null("BossContainer"),
			center,
			safe_radius,
			radius_squared,
			result
		)
		return
	combat_target_index.query_radius_unordered_into(center, radius, result)


## Faction-aware dynamic-target facade. Plant and player candidates keep their
## dedicated lifecycle stores; callers combine them after this enemy query.
func query_hostile_combat_targets_into(
	center: Vector2,
	radius: float,
	source_faction_id: int,
	result: Array[Enemy],
	max_count: int = 0,
	excluded_enemy: Enemy = null,
	relation_service: CombatRelationService = null
) -> void:
	combat_target_index.query_hostile_radius_into(
		center,
		radius,
		source_faction_id,
		result,
		max_count,
		excluded_enemy,
		relation_service
	)


func find_nearest_hostile_combat_target(
	center: Vector2,
	radius: float,
	source_faction_id: int,
	excluded_enemy: Enemy = null,
	relation_service: CombatRelationService = null
) -> Enemy:
	return combat_target_index.find_nearest_hostile(
		center,
		radius,
		source_faction_id,
		excluded_enemy,
		relation_service
	)


func query_combat_targets_in_world_aabb_into(
	world_aabb: Rect2,
	result: Array[Enemy],
	max_count: int = 0
) -> void:
	combat_target_index.query_world_aabb_into(world_aabb, result, max_count)


func _should_use_singleplayer_combat_target_index(
	radius: float,
	max_count: int,
	unordered: bool = false
) -> bool:
	# A non-positive radius means a global query. Buckets cannot prune it, so the
	# direct container scan avoids index indirection without changing complexity.
	if not _singleplayer_combat_target_index_enabled or radius <= 0.0:
		return false
	if _singleplayer_combat_target_index_force_local_queries:
		return true
	# The index now stays current through per-enemy bucket-boundary events, while
	# its repair audit is capped at 16 entries. There is no longer an O(n) first
	# query charge to amortize, so every local nearest/unordered query should use
	# the already-maintained buckets even when it is the only query this frame.
	if unordered or max_count == 1:
		return true
	# Local sorted/bulk queries still have result sorting/output costs. Keep small
	# encounters on direct iteration and switch large waves once bucket pruning
	# consistently wins even for one query per frame.
	return (
		combat_target_index.enemies_by_net_id.size()
		>= SINGLEPLAYER_BULK_INDEX_MIN_TARGETS
	)


func _collect_combat_targets_from_container(container: Node, result: Array[Enemy]) -> void:
	if container == null:
		return
	for child in container.get_children():
		var enemy := child as Enemy
		if CombatTargetIndexScript.is_enemy_queryable(enemy):
			result.append(enemy)


func _append_combat_targets_in_radius(
	container: Node,
	center: Vector2,
	safe_radius: float,
	radius_squared: float,
	result: Array[Enemy]
) -> void:
	if container == null:
		return
	for child in container.get_children():
		var enemy := child as Enemy
		if not CombatTargetIndexScript.is_enemy_queryable(enemy):
			continue
		if safe_radius > 0.0 and center.distance_squared_to(enemy.global_position) > radius_squared:
			continue
		result.append(enemy)


func _find_nearest_combat_target_in_container(
	container: Node,
	center: Vector2,
	radius_squared: float,
	excluded_instance_ids: Dictionary,
	nearest: Enemy
) -> Enemy:
	if container == null:
		return nearest
	var nearest_distance_squared := INF
	var nearest_instance_id := 0
	if nearest != null:
		nearest_distance_squared = center.distance_squared_to(nearest.global_position)
		nearest_instance_id = nearest.get_instance_id()
	var child_index := 0
	while child_index < container.get_child_count():
		var enemy := container.get_child(child_index) as Enemy
		child_index += 1
		if not CombatTargetIndexScript.is_enemy_queryable(enemy):
			continue
		var instance_id := enemy.get_instance_id()
		if excluded_instance_ids.has(instance_id):
			continue
		var distance_squared := center.distance_squared_to(enemy.global_position)
		if distance_squared > radius_squared:
			continue
		if (
			nearest == null
			or distance_squared < nearest_distance_squared
			or (
				distance_squared == nearest_distance_squared
				and instance_id < nearest_instance_id
			)
		):
			nearest = enemy
			nearest_distance_squared = distance_squared
			nearest_instance_id = instance_id
	return nearest


func _retain_nearest_combat_target(
	result: Array[Enemy],
	center: Vector2
) -> void:
	if result.size() <= 1:
		return
	var nearest := result[0]
	var nearest_distance := center.distance_squared_to(nearest.global_position)
	var nearest_instance_id := nearest.get_instance_id()
	for candidate_index in range(1, result.size()):
		var candidate := result[candidate_index]
		var candidate_distance := center.distance_squared_to(candidate.global_position)
		var candidate_instance_id := candidate.get_instance_id()
		if candidate_distance < nearest_distance or (
			candidate_distance == nearest_distance
			and candidate_instance_id < nearest_instance_id
		):
			nearest = candidate
			nearest_distance = candidate_distance
			nearest_instance_id = candidate_instance_id
	result[0] = nearest
	result.resize(1)


func collect_reused_enemy_snapshot_states(
	primary_container: Node,
	secondary_container: Node = null
) -> Array[SnapshotManager.EnemyState]:
	_enemy_snapshot_output.clear()
	_append_enemy_snapshot_states_from_container(primary_container)
	_append_enemy_snapshot_states_from_container(secondary_container)
	# With unique authoritative net IDs, adding every live state makes the cache
	# larger than the output if and only if at least one old ID went stale. The
	# common no-spawn/no-removal snapshot therefore skips all live-ID hash writes.
	if _enemy_snapshot_states_by_net_id.size() == _enemy_snapshot_output.size():
		return _enemy_snapshot_output
	_enemy_snapshot_live_ids.clear()
	for live_state in _enemy_snapshot_output:
		_enemy_snapshot_live_ids[live_state.net_id] = true
	_stale_enemy_snapshot_ids.clear()
	# Direct Dictionary traversal avoids allocating keys() every snapshot. Erase
	# only after traversal so the cached state table remains mutation-safe.
	for cached_id_variant in _enemy_snapshot_states_by_net_id:
		var cached_id := int(cached_id_variant)
		if not _enemy_snapshot_live_ids.has(cached_id):
			_stale_enemy_snapshot_ids.append(cached_id)
	for stale_id in _stale_enemy_snapshot_ids:
		_enemy_snapshot_states_by_net_id.erase(stale_id)
	return _enemy_snapshot_output


func _append_enemy_snapshot_states_from_container(container: Node) -> void:
	if container == null:
		return
	# Godot materializes this child list in one native call. Despite its small
	# temporary Array, this is materially faster at horde scale than crossing the
	# script/native boundary once per child with get_child(index).
	for child in container.get_children():
		var enemy := child as Enemy
		if enemy == null or not is_instance_valid(enemy):
			continue
		var net_id := int(enemy.get_meta(&"net_id", enemy.get_instance_id()))
		if net_id <= 0:
			continue
		var state := (
			_enemy_snapshot_states_by_net_id.get(net_id)
			as SnapshotManager.EnemyState
		)
		if state == null:
			state = SnapshotManager.EnemyState.new()
			_enemy_snapshot_states_by_net_id[net_id] = state
		state.net_id = net_id
		state.position = enemy.global_position
		state.velocity = enemy.velocity
		state.locomotion_state = enemy.get_locomotion_state()
		state.health = enemy.current_health
		state.health_revision = enemy.health_revision
		state.is_dead = enemy.is_dead
		state.visual_status_mask = enemy.get_collectible_visual_status_mask()
		state.faction_id = enemy.get_combat_faction_id()
		state.faction_revision = enemy.get_faction_revision()
		_enemy_snapshot_output.append(state)


func defer_runtime_activation() -> void:
	if _scene_teardown_prepared:
		return
	runtime_activation_deferred = true
	runtime_activated = false
	process_mode = Node.PROCESS_MODE_DISABLED


func activate_runtime() -> void:
	if runtime_activated or _scene_teardown_prepared:
		return
	runtime_activation_deferred = false
	runtime_activated = true
	process_mode = Node.PROCESS_MODE_INHERIT
	_on_runtime_activated()


func _on_runtime_activated() -> void:
	pass


## SceneTree 会先递归移除子实体，再调用运行时根节点的 _exit_tree()。
## 所有主动切场景入口必须先经过这里，让领域账本与网络索引在子实体离树前收束。
func prepare_for_scene_teardown() -> void:
	if _scene_teardown_prepared:
		return
	_scene_teardown_prepared = true
	runtime_activation_deferred = false
	runtime_activated = false
	process_mode = Node.PROCESS_MODE_DISABLED
	var enemy_simulation_coordinator := get_enemy_simulation_coordinator()
	if enemy_simulation_coordinator != null:
		enemy_simulation_coordinator.prepare_combat_services_for_runtime_teardown()
	_enemy_combat_services = null
	_on_scene_teardown_prepared()
	_prepare_nested_combat_runtimes_for_scene_teardown(self)
	# 会话正在整体销毁；本地索引只需静默释放，不能再发布逐实体终结包。
	clear_network_enemy_registry()
	clear_network_pickup_registry()


func is_scene_teardown_prepared() -> bool:
	return _scene_teardown_prepared


func _on_scene_teardown_prepared() -> void:
	pass


func _prepare_nested_combat_runtimes_for_scene_teardown(parent: Node) -> void:
	for child in parent.get_children():
		var nested_runtime := child as CombatRuntimeBase
		if nested_runtime != null:
			nested_runtime.prepare_for_scene_teardown()
			continue
		_prepare_nested_combat_runtimes_for_scene_teardown(child)


func prewarm_shared_runtime_data(preparation_generation: int) -> void:
	var adapter := get_multiplayer_mode_adapter()
	if adapter != null:
		await adapter.prewarm_mode_runtime_data(preparation_generation)


func prepare_shared_runtime_data_and_complete(preparation_generation: int) -> void:
	await prewarm_shared_runtime_data(preparation_generation)
	if (
		is_inside_tree()
		and is_runtime_preparation_generation_preparing(preparation_generation)
	):
		mark_runtime_preparation_complete(preparation_generation)


func has_session_object_pool_scene(scene: PackedScene) -> bool:
	var pool := get_node_or_null("SessionObjectPool") as SessionObjectPool
	return pool != null and pool.is_registered(scene)


func acquire_session_object(scene: PackedScene, strict: bool = false) -> Node:
	var pool := get_node_or_null("SessionObjectPool") as SessionObjectPool
	if pool == null or not pool.is_registered(scene):
		return null
	if strict:
		return pool.try_acquire(scene)
	return pool.acquire(scene)


func release_session_object(instance: Node) -> bool:
	var pool := get_node_or_null("SessionObjectPool") as SessionObjectPool
	return pool != null and pool.release(instance)


func grant_xirang_kill_reward(amount: int) -> bool:
	if amount <= 0 or runtime_mode == RuntimeMode.CLIENT_VIEW:
		return false
	_pending_xirang_kill_reward += amount
	if not _xirang_kill_reward_flush_queued:
		_xirang_kill_reward_flush_queued = true
		call_deferred("_flush_xirang_kill_rewards")
	return true


func grant_xirang_kill_reward_for_defeat(
	amount: int,
	defeat_context: EnemyDefeatContext
) -> bool:
	if (
		defeat_context != null
		and not defeat_context.is_player_reward_eligible()
	):
		return false
	# Keep the existing virtual reward hook intact so Tower Defense fate
	# multipliers and campaign accounting still execute after attribution passed.
	return grant_xirang_kill_reward(amount)


## Canonical shared combat feedback entry point. Concrete game scenes with a
## DamageNumberPool override this; lightweight test/server runtimes keep the
## zero-cost default. Compatibility wrappers below preserve focused call sites.
func show_combat_number(
	_amount: int,
	_spawn_position: Vector2,
	_number_kind: DamageNumberPool.CombatNumberKind,
	_motion_direction: Vector2 = Vector2.ZERO,
	_damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
	_display_priority: DamageNumberPool.DisplayPriority = DamageNumberPool.DisplayPriority.NORMAL
) -> bool:
	return false


func show_damage_number(
	amount: int,
	spawn_position: Vector2,
	impact_direction: Vector2 = Vector2.ZERO,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
	display_priority: DamageNumberPool.DisplayPriority = DamageNumberPool.DisplayPriority.NORMAL
) -> bool:
	return show_combat_number(
		amount,
		spawn_position,
		DamageNumberPool.CombatNumberKind.DAMAGE,
		impact_direction,
		damage_type,
		display_priority
	)


func show_healing_number(
	amount: int,
	spawn_position: Vector2,
	motion_direction: Vector2 = Vector2.ZERO,
	display_priority: DamageNumberPool.DisplayPriority = DamageNumberPool.DisplayPriority.NORMAL
) -> bool:
	return show_combat_number(
		amount,
		spawn_position,
		DamageNumberPool.CombatNumberKind.HEALING,
		motion_direction,
		EnemyConfig.DamageType.PHYSICAL,
		display_priority
	)


func _flush_xirang_kill_rewards() -> void:
	_xirang_kill_reward_flush_queued = false
	var amount := _pending_xirang_kill_reward
	_pending_xirang_kill_reward = 0
	if amount <= 0:
		return
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		if player != null and is_instance_valid(player):
			player.grant_xirang_reward(amount, false)
		return
	for peer_id_variant in peer_players:
		var player_node := peer_players[peer_id_variant] as Player
		if player_node != null and is_instance_valid(player_node):
			player_node.grant_xirang_reward(amount, false)
