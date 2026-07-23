@abstract
extends Node2D
class_name GameRuntimeBase

const CombatTargetIndexScript := preload("res://scene/combat_target_index.gd")
const EnemySpawnEffectBudgetScript := preload("res://scene/enemy_spawn_effect_budget.gd")
const ENEMY_SPAWN_EFFECT_SCENE := preload(
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_spawn_effect.tscn"
)
const BULLET_HIT_EFFECT_POOL_SCENE := preload("res://scene/bullet_hit_effect.tscn")
const ENEMY_HIT_EFFECT_POOL_SCENE := preload("res://scene/enemy/enemy_hit_effect.tscn")
const MOVE_SPEED_TRAIL_EFFECT_POOL_SCENE := preload(
	"res://scene/move_speed_trail_effect.tscn"
)
const CAPOO_MAGE_FIREBALL_IMPACT_POOL_SCENE := preload(
	"res://scene/enemy/capoo/capoo_mage_fireball_impact.tscn"
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
const SINGLEPLAYER_BULK_INDEX_MIN_TARGETS := 512

signal multiplayer_enemy_spawned(net_id: int, enemy_config: EnemyConfig, spawn_position: Vector2)
signal multiplayer_enemy_defeated(net_id: int, defeat_position: Vector2)
signal multiplayer_enemy_removed(net_id: int)
signal multiplayer_enemy_escaped(net_id: int)
signal multiplayer_pickup_spawned(net_id: int, pickup_config: PickupConfig, spawn_position: Vector2)
signal multiplayer_pickup_collected(
	net_id: int,
	collector_peer_id: int,
	pickup_config: PickupConfig,
	applied_immediately: bool
)
signal multiplayer_pickup_removed(net_id: int)
signal multiplayer_merchant_active_changed(active: bool)
signal multiplayer_flow_state_changed(step_id: StringName, state: int, countdown_seconds: int)
signal multiplayer_boss_started(net_id: int, boss_config: BossConfig, spawn_position: Vector2)
signal multiplayer_defeat_started
signal multiplayer_victory_started
signal multiplayer_revive_all_requested
signal multiplayer_base_health_changed(current_health: int, maximum_health: int, revision: int)
signal multiplayer_tower_defense_wave_progress_changed(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
)
signal multiplayer_plant_spawned(
	request_id: int,
	owner_peer_id: int,
	net_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	current_health: int,
	maximum_health: int,
	health_revision: int
)
signal multiplayer_plant_placement_rejected(
	request_id: int,
	requester_peer_id: int,
	reason: StringName
)
signal multiplayer_plant_health_changed(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
)
signal multiplayer_plant_damage_applied(
	net_id: int,
	applied_damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	world_position: Vector2
)
signal multiplayer_plant_healing_applied(
	net_id: int,
	applied_healing: int,
	world_position: Vector2
)
signal multiplayer_plant_removed(net_id: int, was_destroyed: bool)
## Authoritative terrain batches are already committed locally when emitted.
## Revisions must be positive, strictly monotonic, and advance exactly once per
## non-empty batch. cell_xy stores x/y pairs parallel to terrain_types.
signal multiplayer_terrain_delta(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
)
signal multiplayer_plant_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i
)
signal multiplayer_inventory_plant_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
)
signal multiplayer_inventory_changed(peer_id: int)
signal return_to_lobby_requested
signal runtime_preparation_progress_changed(stage: String, completed: int, total: int)
signal runtime_preparation_completed

enum RuntimeMode {
	SINGLEPLAYER,
	HOST_AUTHORITY,
	CLIENT_VIEW,
}

enum WaveState {
	PRE_WAVE,
	WAVE_ACTIVE,
	INTERMISSION,
	VICTORY,
	DEFEAT,
	BOSS_INTRO,
	BOSS_ACTIVE,
}

@export var runtime_mode: RuntimeMode = RuntimeMode.SINGLEPLAYER

@onready var enemy_container: Node2D = $EnemyContainer
@onready var grid_pathfinder: Node = $GridPathfinder
@onready var capoo_projectile_motion_system: Node = $CapooProjectileMotionSystem
@onready var day_night_controller: DayNightController = $DayNightController

var player: Player = null
var wave_state: WaveState = WaveState.PRE_WAVE
var multiplayer_local_peer_id: int = 0
var peer_players: Dictionary = {}
var multiplayer_pickups: Dictionary = {}
var multiplayer_enemy_ids_by_instance: Dictionary = {}
var multiplayer_enemies_by_net_id: Dictionary = {}
var combat_target_index = CombatTargetIndexScript.new()
var _singleplayer_combat_target_index_enabled := false
var _singleplayer_combat_target_index_force_local_queries := false
var _enemy_snapshot_states_by_net_id: Dictionary = {}
var _enemy_snapshot_output: Array[SnapshotManager.EnemyState] = []
var _enemy_snapshot_live_ids: Dictionary = {}
var _stale_enemy_snapshot_ids: Array[int] = []
var _enemy_spawn_effect_budget = EnemySpawnEffectBudgetScript.new()
var runtime_activation_deferred := false
var runtime_activated := false
var runtime_preparation_complete := false
var runtime_preparation_stage := "等待场景初始化"
var runtime_preparation_completed_steps := 0
var runtime_preparation_total_steps := 1
var _pending_xirang_kill_reward: int = 0
var _xirang_kill_reward_flush_queued: bool = false


func transition_world_to_night(duration_seconds: float = -1.0) -> void:
	day_night_controller.transition_to_night(duration_seconds)


func transition_world_to_day(duration_seconds: float = -1.0) -> void:
	day_night_controller.transition_to_day(duration_seconds)


func _apply_wave_start_lighting(_wave_number: int) -> void:
	# Every normal wave uses night only while its combat state is active.
	# PRE_WAVE and INTERMISSION own the matching transition back to daylight.
	transition_world_to_night()


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
@abstract func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]
@abstract func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]
@abstract func apply_remote_flow_state(step_id: StringName, state: int, seconds: int) -> void
@abstract func get_flow_state_snapshot() -> Dictionary
@abstract func apply_remote_boss_started(
	net_id: int,
	boss_config: BossConfig,
	spawn_position: Vector2
) -> void
@abstract func apply_remote_defeat() -> void
@abstract func apply_remote_victory() -> void
@abstract func apply_remote_enemy_count(alive_count: int) -> void
@abstract func apply_remote_merchant_active(active: bool) -> void
@abstract func play_remote_enemy_spawn_effect(spawn_global_position: Vector2) -> void
@abstract func try_purchase_skill1_for_peer(peer_id: int) -> int
@abstract func apply_skill1_purchase_state(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	skill1_upgrade_level: int = -1,
	skill1_charge_duration: float = -1.0
) -> void
@abstract func show_local_skill1_purchase_result(result_code: int) -> void
@abstract func try_refresh_luoxi_collectibles_for_peer(peer_id: int) -> int
@abstract func get_luoxi_collectible_refresh_count(peer_id: int) -> int
@abstract func try_claim_luoxi_collectible_for_peer(
	peer_id: int,
	config_path_or_choice: Variant
) -> int
@abstract func has_luoxi_collectible_claimed(peer_id: int) -> bool
@abstract func record_luoxi_collectible_claim(peer_id: int) -> void
@abstract func mark_luoxi_collectible_claimed(peer_id: int) -> void
@abstract func show_local_luoxi_collectible_result(result_code: int) -> void
@abstract func show_local_luoxi_refresh_result(
	result_code: int,
	refresh_count: int,
	current_xirang: int
) -> void
@abstract func show_debug_collectible_grant_result(config_path: String, success: bool) -> void
func show_simple_crafting_result(
	_recipe_id: StringName,
	_result: StringName,
	_request_token: int
) -> void:
	pass


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


func find_nearest_enemy_attack_target(
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


## Fills caller-owned storage with every living allied player in an exact
## world-space circle. Plant auras use this facade in both solo and Host modes
## without rebuilding the scene tree or allocating a temporary player list.
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


## Standard mode has no plant population. Tower-defense runtimes override this
## contract with their maintained plant spatial index.
func query_living_plants_in_radius_into(
	_center: Vector2,
	_radius: float,
	result: Array[PlantDefense]
) -> void:
	result.clear()


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
	# path used by Game and GameTowerDefense.
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


func get_multiplayer_plant_node(_net_id: int) -> PlantDefense:
	return null


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
		state.is_dead = enemy.is_dead
		state.visual_status_mask = enemy.get_collectible_visual_status_mask()
		_enemy_snapshot_output.append(state)


func defer_runtime_activation() -> void:
	runtime_activation_deferred = true
	runtime_activated = false
	process_mode = Node.PROCESS_MODE_DISABLED


func activate_runtime() -> void:
	if runtime_activated:
		return
	runtime_activation_deferred = false
	runtime_activated = true
	process_mode = Node.PROCESS_MODE_INHERIT
	_on_runtime_activated()


func _on_runtime_activated() -> void:
	pass


func update_runtime_preparation_progress(stage: String, completed: int, total: int) -> void:
	runtime_preparation_stage = stage
	runtime_preparation_total_steps = maxi(total, 1)
	runtime_preparation_completed_steps = clampi(
		completed,
		0,
		runtime_preparation_total_steps
	)
	runtime_preparation_progress_changed.emit(
		runtime_preparation_stage,
		runtime_preparation_completed_steps,
		runtime_preparation_total_steps
	)


func mark_runtime_preparation_complete() -> void:
	if runtime_preparation_complete:
		return
	runtime_preparation_complete = true
	update_runtime_preparation_progress("战场准备完成", 1, 1)
	runtime_preparation_completed.emit()


func is_runtime_preparation_complete() -> bool:
	return runtime_preparation_complete


func get_runtime_preparation_progress() -> Dictionary:
	return {
		"stage": runtime_preparation_stage,
		"completed": runtime_preparation_completed_steps,
		"total": runtime_preparation_total_steps,
	}


func prewarm_shared_runtime_data() -> void:
	if LuoxiMerchant.is_collectible_cache_ready():
		return
	var config_paths := LuoxiMerchant.get_collectible_config_paths()
	const CONFIGS_PER_FRAME := 8
	var total_batches := maxi(ceili(float(config_paths.size()) / CONFIGS_PER_FRAME), 1)
	var completed_batches := 0
	for batch_start in range(0, config_paths.size(), CONFIGS_PER_FRAME):
		var batch_end := mini(batch_start + CONFIGS_PER_FRAME, config_paths.size())
		for config_index in range(batch_start, batch_end):
			var config := load(config_paths[config_index]) as PickupConfig
			LuoxiMerchant.cache_collectible_config(config)
		completed_batches += 1
		update_runtime_preparation_progress(
			"缓存收藏品配置…",
			completed_batches,
			total_batches
		)
		await get_tree().process_frame
		if not is_inside_tree():
			return
	LuoxiMerchant.finish_collectible_cache_warmup()


func prepare_shared_runtime_data_and_complete() -> void:
	await prewarm_shared_runtime_data()
	if is_inside_tree():
		mark_runtime_preparation_complete()


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


func supports_tower_defense() -> bool:
	return false


func request_tower_defense_wave_start(_requester_peer_id: int = 0) -> bool:
	return false


func consume_next_player_respawn_delay(_peer_id: int) -> float:
	return 10.0


func update_player_respawn_countdown(_peer_id: int, _seconds_left: int) -> void:
	pass


func clear_player_respawn_countdown(_peer_id: int) -> void:
	pass


## Runtime modes with a fixed multiplayer respawn layout can return a world-space
## position here. Returning null preserves the standard mode's living-player
## revive behavior.
func get_fixed_multiplayer_respawn_position(_peer_id: int) -> Variant:
	return null


func get_base_health_snapshot() -> Dictionary:
	return {}


func apply_remote_base_health(
	_current_health: int,
	_maximum_health: int,
	_revision: int
) -> void:
	pass


func apply_remote_enemy_escape(_net_id: int) -> void:
	pass


func request_multiplayer_plant_placement(
	_requester_peer_id: int,
	_request_id: int,
	_plant_id: StringName,
	_anchor: Vector2i
) -> void:
	pass


func request_multiplayer_inventory_plant_placement(
	_requester_peer_id: int,
	_request_id: int,
	_plant_id: StringName,
	_anchor: Vector2i,
	_slot_index: int,
	_expected_inventory_revision: int,
	_item_config_path: String
) -> void:
	pass


func apply_remote_plant_spawn(
	_request_id: int,
	_owner_peer_id: int,
	_net_id: int,
	_plant_id: StringName,
	_anchor: Vector2i,
	_current_health: int,
	_maximum_health: int,
	_health_revision: int
) -> void:
	pass


func apply_remote_plant_health(
	_net_id: int,
	_current_health: int,
	_maximum_health: int,
	_health_revision: int
) -> void:
	pass


func apply_remote_plant_removed(_net_id: int) -> void:
	pass


## Reliable removal events carry the terminal reason so client-only feedback does
## not depend on an unreliable health packet arriving first.
func apply_remote_plant_removed_with_reason(
	net_id: int,
	_was_destroyed: bool
) -> void:
	apply_remote_plant_removed(net_id)


## Complete-state repair uses this path to prune a stale local replica without
## presenting the correction as a newly observed gameplay removal. Runtimes
## without a distinct visual lifecycle retain the existing removal behavior.
func apply_remote_plant_removed_silently(net_id: int) -> void:
	apply_remote_plant_removed(net_id)


func apply_remote_plant_placement_rejected(_request_id: int, _reason: StringName) -> void:
	pass


func has_multiplayer_plant(_net_id: int) -> bool:
	return false


func get_multiplayer_plant_snapshots() -> Array[Dictionary]:
	return []


## Only runtimes that own replicated terrain overrides should opt in. The
## standard runtime deliberately keeps the no-op contract below.
func supports_multiplayer_terrain_state() -> bool:
	return false


## Returns the complete authoritative override set relative to the authored
## map: {revision: int, cell_xy: PackedInt32Array, terrain_types: PackedInt32Array}.
## EMPTY (-1) is a valid terrain value and must not be discarded.
func get_multiplayer_terrain_snapshot() -> Dictionary:
	return {
		"revision": 0,
		"cell_xy": PackedInt32Array(),
		"terrain_types": PackedInt32Array(),
	}


## Client-view implementations must replace the complete override set
## atomically and return false without mutation when the payload is invalid.
func apply_remote_terrain_snapshot(
	_revision: int,
	_cell_xy: PackedInt32Array,
	_terrain_types: PackedInt32Array
) -> bool:
	return false


## Client-view implementations must apply the whole revision atomically and
## return false without mutation when the payload is invalid.
func apply_remote_terrain_delta(
	_revision: int,
	_cell_xy: PackedInt32Array,
	_terrain_types: PackedInt32Array
) -> bool:
	return false


func get_tower_defense_wave_progress_snapshot() -> Dictionary:
	return {}


func apply_remote_tower_defense_wave_progress(
	_wave_number: int,
	_defeated: int,
	_escaped: int,
	_resolved: int,
	_total: int
) -> void:
	pass
