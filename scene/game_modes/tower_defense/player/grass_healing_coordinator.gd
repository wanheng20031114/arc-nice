extends Node
class_name GrassHealingCoordinator

const BASE_HEAL_RATIO := 0.20
const HEAL_INTERVAL_SECONDS := 1.0

@export var terrain_map: DualGridTilemap
@export var player_roster_coordinator: TowerDefensePlayerRosterCoordinator

var _grass_elapsed_by_player_id: Dictionary[int, float] = {}


func _ready() -> void:
	if (
		terrain_map == null
		or player_roster_coordinator == null
	):
		push_error(
			"GrassHealingCoordinator requires terrain and player roster."
		)
		set_physics_process(false)


func _exit_tree() -> void:
	if player_roster_coordinator != null:
		for player in player_roster_coordinator.get_all_players():
			player.set_grass_healing_effect_active(false)
	_grass_elapsed_by_player_id.clear()


func _physics_process(delta: float) -> void:
	advance_grass_healing(delta)


func advance_grass_healing(delta: float) -> void:
	if delta <= 0.0 or not is_finite(delta):
		return
	var active_player_ids: Dictionary[int, bool] = {}
	for player in player_roster_coordinator.get_all_players():
		if player == null or not is_instance_valid(player):
			continue
		var player_id := player.get_instance_id()
		active_player_ids[player_id] = true
		var is_on_grass := (
			not player.is_dead
			and terrain_map.is_world_position_plantable(player.global_position)
		)
		player.set_grass_healing_effect_active(is_on_grass)
		if not is_on_grass:
			_grass_elapsed_by_player_id.erase(player_id)
			continue
		if (
			player_roster_coordinator.runtime_mode
			== CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		):
			_grass_elapsed_by_player_id.erase(player_id)
			continue
		var elapsed := float(_grass_elapsed_by_player_id.get(player_id, 0.0)) + delta
		var completed_ticks := floori(elapsed / HEAL_INTERVAL_SECONDS)
		_grass_elapsed_by_player_id[player_id] = (
			elapsed - float(completed_ticks) * HEAL_INTERVAL_SECONDS
		)
		if completed_ticks <= 0:
			continue
		var heal_per_tick := ceili(float(player.max_health) * BASE_HEAL_RATIO)
		player.heal(heal_per_tick * completed_ticks)
	for tracked_player_id in _grass_elapsed_by_player_id.keys():
		if not active_player_ids.has(int(tracked_player_id)):
			_grass_elapsed_by_player_id.erase(tracked_player_id)
