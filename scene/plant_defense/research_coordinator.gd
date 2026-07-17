extends Node
class_name ResearchCoordinator

signal research_state_changed
signal research_milestone_changed(player_key: int)

enum GlobalResearchState {
	AVAILABLE,
	RESEARCHING,
	COMPLETED,
}

const RESULT_SUCCESS := &"success"
const RESULT_MISSING_INPUT := &"missing_input"
const RESULT_IN_PROGRESS := &"in_progress"
const RESULT_REQUEST_SENT := &"request_sent"
const RESULT_COMPLETED := &"completed"
const RESULT_INSUFFICIENT_XIRANG := &"insufficient_xirang"
const RESULT_UNAVAILABLE := &"unavailable"
const RESULT_MAX_LEVEL := &"max_level"

const GLOBAL_RESEARCH_DURATION_SECONDS := 60.0
const GLOBAL_PHYSICAL_DEFENSE_BONUS := 10
const PLANK := preload("res://resources/config/materials/material_plank.tres")
const SAPLING := preload("res://resources/config/materials/material_sapling.tres")
const WATER_BOTTLE := preload(
	"res://resources/config/materials/material_water_bottle.tres"
)
const GLOBAL_REQUIREMENTS: Array[Dictionary] = [
	{"item": PLANK, "count": 50},
	{"item": SAPLING, "count": 20},
	{"item": WATER_BOTTLE, "count": 20},
]

@onready var research_tick_timer: Timer = $ResearchTickTimer

var production_coordinator: ProductionCoordinator = null
var plant_system: PlantSystem = null
var game: GameTowerDefense = null
var authoritative_processing_enabled := true
var global_state: GlobalResearchState = GlobalResearchState.AVAILABLE
var global_elapsed_seconds := 0.0
var player_technology_levels: Dictionary = {}
var research_revision := 0
var has_remote_snapshot := false


func _ready() -> void:
	research_tick_timer.timeout.connect(_on_research_tick)
	_refresh_timer_state()


func setup(
	new_production_coordinator: ProductionCoordinator,
	new_plant_system: PlantSystem,
	new_game: GameTowerDefense
) -> void:
	production_coordinator = new_production_coordinator
	plant_system = new_plant_system
	game = new_game
	_apply_global_bonus()


func set_authoritative_processing_enabled(enabled: bool) -> void:
	authoritative_processing_enabled = enabled
	_refresh_timer_state()


func register_player(player: Player) -> void:
	if player == null:
		return
	var key := _get_player_key(player)
	if not player_technology_levels.has(key):
		player_technology_levels[key] = player.get_research_technology_level()
	player.set_research_technology_level(int(player_technology_levels[key]))


func get_global_material_total(item: PickupConfig) -> int:
	if production_coordinator == null:
		return 0
	return production_coordinator.get_total_item_count(item)


func get_global_progress_ratio() -> float:
	if global_state == GlobalResearchState.COMPLETED:
		return 1.0
	return clampf(
		global_elapsed_seconds / GLOBAL_RESEARCH_DURATION_SECONDS,
		0.0,
		1.0
	)


func try_start_global_research() -> StringName:
	if not authoritative_processing_enabled or production_coordinator == null:
		return RESULT_UNAVAILABLE
	match global_state:
		GlobalResearchState.RESEARCHING:
			return RESULT_IN_PROGRESS
		GlobalResearchState.COMPLETED:
			return RESULT_COMPLETED
	var result := production_coordinator.try_consume_item_requirements(
		GLOBAL_REQUIREMENTS
	)
	if result != ProductionCoordinator.RESULT_SUCCESS:
		return (
			RESULT_MISSING_INPUT
			if result == ProductionCoordinator.RESULT_MISSING_INPUT
			else RESULT_UNAVAILABLE
		)
	global_state = GlobalResearchState.RESEARCHING
	global_elapsed_seconds = 0.0
	_bump_revision()
	research_milestone_changed.emit(0)
	return RESULT_SUCCESS


func advance_global_research(delta: float) -> void:
	if (
		not authoritative_processing_enabled
		or global_state != GlobalResearchState.RESEARCHING
	):
		return
	global_elapsed_seconds = minf(
		global_elapsed_seconds + maxf(delta, 0.0),
		GLOBAL_RESEARCH_DURATION_SECONDS
	)
	if global_elapsed_seconds + 0.0001 >= GLOBAL_RESEARCH_DURATION_SECONDS:
		global_state = GlobalResearchState.COMPLETED
		global_elapsed_seconds = GLOBAL_RESEARCH_DURATION_SECONDS
		_apply_global_bonus()
	_bump_revision()
	if global_state == GlobalResearchState.COMPLETED:
		research_milestone_changed.emit(0)


func try_purchase_player_technology(player: Player) -> StringName:
	if not authoritative_processing_enabled or player == null or player.is_dead:
		return RESULT_UNAVAILABLE
	register_player(player)
	var key := _get_player_key(player)
	var current_level := int(player_technology_levels.get(key, 0))
	if current_level >= Player.RESEARCH_TECHNOLOGY_MAX_LEVEL:
		return RESULT_MAX_LEVEL
	var cost := int(Player.RESEARCH_TECHNOLOGY_COSTS[current_level])
	if not player.try_spend_xirang(cost):
		return RESULT_INSUFFICIENT_XIRANG
	var next_level := current_level + 1
	player_technology_levels[key] = next_level
	player.set_research_technology_level(next_level)
	_bump_revision()
	research_milestone_changed.emit(key)
	return RESULT_SUCCESS


func get_player_technology_level(player: Player) -> int:
	if player == null:
		return 0
	var key := _get_player_key(player)
	return int(
		player_technology_levels.get(
			key,
			player.get_research_technology_level()
		)
	)


func export_runtime_state() -> Dictionary:
	return {
		"schema": 1,
		"revision": research_revision,
		"global_state": int(global_state),
		"global_elapsed": global_elapsed_seconds,
		"player_levels": player_technology_levels.duplicate(),
	}


func apply_multiplayer_runtime_state(state: Dictionary) -> void:
	if state.is_empty() or int(state.get("schema", 0)) != 1:
		return
	var incoming_revision := maxi(int(state.get("revision", 0)), 0)
	if has_remote_snapshot and incoming_revision <= research_revision:
		return
	has_remote_snapshot = true
	research_revision = incoming_revision
	global_state = clampi(
		int(state.get("global_state", GlobalResearchState.AVAILABLE)),
		GlobalResearchState.AVAILABLE,
		GlobalResearchState.COMPLETED
	)
	global_elapsed_seconds = clampf(
		float(state.get("global_elapsed", 0.0)),
		0.0,
		GLOBAL_RESEARCH_DURATION_SECONDS
	)
	var incoming_levels := state.get("player_levels", {}) as Dictionary
	player_technology_levels = incoming_levels.duplicate()
	_apply_global_bonus()
	_apply_player_levels_to_runtime()
	research_state_changed.emit()


func _get_player_key(player: Player) -> int:
	return player.peer_id if player.peer_id > 0 else 0


func _apply_global_bonus() -> void:
	if plant_system == null:
		return
	plant_system.set_global_physical_defense_bonus(
		GLOBAL_PHYSICAL_DEFENSE_BONUS
		if global_state == GlobalResearchState.COMPLETED
		else 0
	)


func _apply_player_levels_to_runtime() -> void:
	if game == null:
		return
	if game.runtime_mode == GameTowerDefense.RuntimeMode.SINGLEPLAYER:
		if game.player != null:
			game.player.set_research_technology_level(
				int(player_technology_levels.get(0, 0))
			)
		return
	for key in player_technology_levels:
		var player := game.get_player_for_peer(int(key))
		if player != null:
			player.set_research_technology_level(
				int(player_technology_levels[key])
			)


func _bump_revision() -> void:
	research_revision += 1
	research_state_changed.emit()


func _on_research_tick() -> void:
	if authoritative_processing_enabled:
		advance_global_research(research_tick_timer.wait_time)
	elif global_state == GlobalResearchState.RESEARCHING:
		global_elapsed_seconds = minf(
			global_elapsed_seconds + research_tick_timer.wait_time,
			GLOBAL_RESEARCH_DURATION_SECONDS
		)
		research_state_changed.emit()


func _refresh_timer_state() -> void:
	if not is_node_ready():
		return
	if research_tick_timer.is_stopped():
		research_tick_timer.start()
