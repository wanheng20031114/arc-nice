@abstract
extends Node2D
class_name GameRuntimeBase

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
signal multiplayer_plant_removed(net_id: int)
signal multiplayer_plant_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i
)
signal return_to_lobby_requested

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

var player: Player = null
var wave_state: WaveState = WaveState.PRE_WAVE
var multiplayer_local_peer_id: int = 0
var peer_players: Dictionary = {}
var multiplayer_pickups: Dictionary = {}
var multiplayer_enemy_ids_by_instance: Dictionary = {}
var multiplayer_enemies_by_net_id: Dictionary = {}


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


func supports_tower_defense() -> bool:
	return false


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


func apply_remote_plant_placement_rejected(_request_id: int, _reason: StringName) -> void:
	pass


func has_multiplayer_plant(_net_id: int) -> bool:
	return false


func get_multiplayer_plant_snapshots() -> Array[Dictionary]:
	return []


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
