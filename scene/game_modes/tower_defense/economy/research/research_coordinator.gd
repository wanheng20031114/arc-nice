extends CraftingResearchStateProvider
class_name ResearchCoordinator

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

const BUILDING_DEFENSE_RESEARCH_ID := GlobalResearchRegistry.BUILDING_DEFENSE_ID
const PLAYER_MOVE_SPEED_RESEARCH_ID := GlobalResearchRegistry.PLAYER_MOVE_SPEED_ID
const BAMBOO_MORTAR_CRAFTING_RESEARCH_ID := (
	GlobalResearchRegistry.BAMBOO_MORTAR_CRAFTING_ID
)
const HYDRANGEA_RAIN_TOWER_CRAFTING_RESEARCH_ID := (
	GlobalResearchRegistry.HYDRANGEA_RAIN_TOWER_CRAFTING_ID
)
const VEGETATION_STAKE_SPREAD_ENHANCEMENT_RESEARCH_ID := (
	GlobalResearchRegistry.VEGETATION_STAKE_SPREAD_ENHANCEMENT_ID
)
const VEGETATION_ENHANCEMENT_RESEARCH_ID := (
	GlobalResearchRegistry.VEGETATION_ENHANCEMENT_ID
)
const WATER_COLLECTION_RATE_ENHANCEMENT_RESEARCH_ID := (
	GlobalResearchRegistry.WATER_COLLECTION_RATE_ENHANCEMENT_ID
)
const FENCE_REINFORCEMENT_RESEARCH_ID := (
	GlobalResearchRegistry.FENCE_REINFORCEMENT_ID
)
const GLOBAL_RESEARCH_DURATION_SECONDS := 60.0
const GLOBAL_PHYSICAL_DEFENSE_BONUS := 10
const GLOBAL_PLAYER_MOVE_SPEED_BONUS := 15.0
const RUNTIME_STATE_SCHEMA := 3
const MAX_MULTIPLAYER_PLAYER_LEVEL_ENTRIES := 64

const PLANK := preload("res://resources/config/materials/material_plank.tres")
const SAPLING := preload("res://resources/config/materials/material_sapling.tres")
const WATER_BOTTLE := preload(
	"res://resources/config/materials/material_water_bottle.tres"
)
# 保留旧接口所公开的建筑防御研究投入；实际研究从配置资源读取。
const GLOBAL_REQUIREMENTS: Array[Dictionary] = [
	{"item": PLANK, "count": 50},
	{"item": SAPLING, "count": 20},
	{"item": WATER_BOTTLE, "count": 20},
]

@onready var research_tick_timer: Timer = $ResearchTickTimer

var production_coordinator: ProductionCoordinator = null
var plant_system: PlantSystem = null
var player_roster_coordinator: TowerDefensePlayerRosterCoordinator = null
var authoritative_processing_enabled := true
var global_research_states: Dictionary = {}
var global_research_elapsed: Dictionary = {}
var active_global_research_id: StringName = &""
var player_technology_levels: Dictionary = {}
var registered_players: Dictionary = {}
var research_revision := 0
var has_remote_snapshot := false

# 兼容原有公开字段：它们现在代表建筑结构强化项目。
var global_state: GlobalResearchState:
	get:
		return get_global_research_state(BUILDING_DEFENSE_RESEARCH_ID)
	set(value):
		global_research_states[BUILDING_DEFENSE_RESEARCH_ID] = value

var global_elapsed_seconds: float:
	get:
		return get_global_elapsed_seconds(BUILDING_DEFENSE_RESEARCH_ID)
	set(value):
		global_research_elapsed[BUILDING_DEFENSE_RESEARCH_ID] = maxf(value, 0.0)


func _init() -> void:
	for config in GlobalResearchRegistry.get_all_configs():
		global_research_states[config.research_id] = GlobalResearchState.AVAILABLE
		global_research_elapsed[config.research_id] = 0.0


func _ready() -> void:
	research_tick_timer.timeout.connect(_on_research_tick)
	_refresh_timer_state()


func setup(
	new_production_coordinator: ProductionCoordinator,
	new_plant_system: PlantSystem,
	new_player_roster_coordinator: TowerDefensePlayerRosterCoordinator
) -> void:
	production_coordinator = new_production_coordinator
	plant_system = new_plant_system
	player_roster_coordinator = new_player_roster_coordinator
	_apply_global_bonuses()


func set_authoritative_processing_enabled(enabled: bool) -> void:
	authoritative_processing_enabled = enabled
	_refresh_timer_state()


func register_player(player: Player) -> void:
	if player == null:
		return
	var key := _get_player_key(player)
	registered_players[key] = weakref(player)
	if not player_technology_levels.has(key):
		player_technology_levels[key] = player.get_research_technology_level()
	_apply_research_state_to_player(
		player,
		int(player_technology_levels.get(key, 0))
	)


## 地下路线/作战只消费研究账本中的永久层：角色技术等级与
## 已完成的全局移速研究。战斗内临时双防不在此入口，换场时由 Player 清零。
func apply_persistent_player_modifiers(
	player: Player,
	ledger_peer_id: int
) -> bool:
	var expected_peer_id := player.peer_id if player != null and player.peer_id > 0 else 0
	if (
		player == null
		or not is_instance_valid(player)
		or ledger_peer_id != expected_peer_id
		or not player_technology_levels.has(ledger_peer_id)
		or typeof(player_technology_levels[ledger_peer_id]) != TYPE_INT
	):
		return false
	var technology_level := int(player_technology_levels[ledger_peer_id])
	if technology_level < 0 or technology_level > Player.RESEARCH_TECHNOLOGY_MAX_LEVEL:
		return false
	var move_speed_bonus := _get_completed_global_effect_total(
		GlobalResearchConfig.EffectType.PLAYER_MOVE_SPEED
	)
	player.set_research_technology_level(technology_level)
	player.set_research_global_move_speed_bonus(move_speed_bonus)
	return (
		player.get_research_technology_level() == technology_level
		and is_equal_approx(
			player.research_global_move_speed_bonus,
			move_speed_bonus
		)
	)


func remap_player_peer_state(old_peer_id: int, new_peer_id: int) -> bool:
	if (
		old_peer_id <= 0
		or new_peer_id <= 0
		or old_peer_id == new_peer_id
		or not player_technology_levels.has(old_peer_id)
		or player_technology_levels.has(new_peer_id)
	):
		return false
	player_technology_levels[new_peer_id] = player_technology_levels[old_peer_id]
	player_technology_levels.erase(old_peer_id)
	registered_players.erase(old_peer_id)
	research_revision += 1
	research_state_changed.emit()
	return true


func get_global_research_configs() -> Array[GlobalResearchConfig]:
	return GlobalResearchRegistry.get_all_configs()


func get_global_research_config(
	research_id: StringName
) -> GlobalResearchConfig:
	return GlobalResearchRegistry.get_config(research_id)


func get_global_research_state(
	research_id: StringName = BUILDING_DEFENSE_RESEARCH_ID
) -> GlobalResearchState:
	if GlobalResearchRegistry.get_config(research_id) == null:
		return GlobalResearchState.AVAILABLE
	return clampi(
		int(global_research_states.get(
			research_id,
			GlobalResearchState.AVAILABLE
		)),
		GlobalResearchState.AVAILABLE,
		GlobalResearchState.COMPLETED
	)


func get_global_elapsed_seconds(
	research_id: StringName = BUILDING_DEFENSE_RESEARCH_ID
) -> float:
	var config := GlobalResearchRegistry.get_config(research_id)
	if config == null:
		return 0.0
	return clampf(
		float(global_research_elapsed.get(research_id, 0.0)),
		0.0,
		config.duration_seconds
	)


func get_global_research_duration(research_id: StringName) -> float:
	var config := GlobalResearchRegistry.get_config(research_id)
	return config.duration_seconds if config != null else 0.0


func get_global_research_requirements(
	research_id: StringName
) -> Array[Dictionary]:
	var config := GlobalResearchRegistry.get_config(research_id)
	return config.get_requirements() if config != null else []


func get_active_global_research_id() -> StringName:
	return active_global_research_id


func get_completed_global_research_ids() -> Array[StringName]:
	var completed_ids: Array[StringName] = []
	for config in GlobalResearchRegistry.get_all_configs():
		if (
			get_global_research_state(config.research_id)
			== GlobalResearchState.COMPLETED
		):
			completed_ids.append(config.research_id)
	return completed_ids


func is_global_research_completed(research_id: StringName) -> bool:
	return (
		GlobalResearchRegistry.get_config(research_id) != null
		and get_global_research_state(research_id)
		== GlobalResearchState.COMPLETED
	)


func get_vegetation_spread_speed_multiplier() -> float:
	var multiplier := 1.0
	for config in GlobalResearchRegistry.get_all_configs():
		if (
			config.effect_type
			== GlobalResearchConfig.EffectType.VEGETATION_SPREAD_SPEED_MULTIPLIER
			and get_global_research_state(config.research_id)
			== GlobalResearchState.COMPLETED
		):
			multiplier *= config.effect_amount
	return multiplier


func get_grass_heal_ratio_bonus() -> float:
	return _get_completed_global_effect_total(
		GlobalResearchConfig.EffectType.GRASS_HEAL_RATIO_BONUS
	)


func get_water_collector_duration_multiplier() -> float:
	var multiplier := 1.0
	for config in GlobalResearchRegistry.get_all_configs():
		if (
			config.effect_type
			== GlobalResearchConfig.EffectType.WATER_COLLECTOR_DURATION_MULTIPLIER
			and get_global_research_state(config.research_id)
			== GlobalResearchState.COMPLETED
		):
			multiplier = minf(multiplier, config.effect_amount)
	return multiplier


func get_fence_max_health_bonus() -> int:
	return roundi(_get_completed_global_effect_total(
		GlobalResearchConfig.EffectType.FENCE_REINFORCEMENT
	))


func get_fence_physical_defense_bonus() -> int:
	return roundi(_get_completed_global_secondary_effect_total(
		GlobalResearchConfig.EffectType.FENCE_REINFORCEMENT
	))


func get_global_material_total(item: PickupConfig) -> int:
	if production_coordinator == null:
		return 0
	return production_coordinator.get_total_item_count(item)


func get_global_progress_ratio(
	research_id: StringName = BUILDING_DEFENSE_RESEARCH_ID
) -> float:
	var config := GlobalResearchRegistry.get_config(research_id)
	if config == null:
		return 0.0
	if get_global_research_state(research_id) == GlobalResearchState.COMPLETED:
		return 1.0
	return clampf(
		get_global_elapsed_seconds(research_id) / config.duration_seconds,
		0.0,
		1.0
	)


func try_start_global_research(
	research_id: StringName = BUILDING_DEFENSE_RESEARCH_ID
) -> StringName:
	if not authoritative_processing_enabled or production_coordinator == null:
		return RESULT_UNAVAILABLE
	var config := GlobalResearchRegistry.get_config(research_id)
	if config == null:
		return RESULT_UNAVAILABLE
	match get_global_research_state(research_id):
		GlobalResearchState.RESEARCHING:
			return RESULT_IN_PROGRESS
		GlobalResearchState.COMPLETED:
			return RESULT_COMPLETED
	if not active_global_research_id.is_empty():
		return RESULT_IN_PROGRESS
	var result := production_coordinator.try_consume_item_requirements(
		config.get_requirements()
	)
	if result != ProductionCoordinator.RESULT_SUCCESS:
		return (
			RESULT_MISSING_INPUT
			if result == ProductionCoordinator.RESULT_MISSING_INPUT
			else RESULT_UNAVAILABLE
		)
	global_research_states[research_id] = GlobalResearchState.RESEARCHING
	global_research_elapsed[research_id] = 0.0
	active_global_research_id = research_id
	_bump_revision()
	_refresh_timer_state()
	research_milestone_changed.emit(0)
	return RESULT_SUCCESS


func advance_global_research(delta: float) -> void:
	if not authoritative_processing_enabled or active_global_research_id.is_empty():
		return
	var research_id := active_global_research_id
	var config := GlobalResearchRegistry.get_config(research_id)
	if (
		config == null
		or get_global_research_state(research_id)
		!= GlobalResearchState.RESEARCHING
	):
		return
	var elapsed := minf(
		get_global_elapsed_seconds(research_id) + maxf(delta, 0.0),
		config.duration_seconds
	)
	global_research_elapsed[research_id] = elapsed
	if elapsed + 0.0001 < config.duration_seconds:
		research_state_changed.emit()
		return
	global_research_states[research_id] = GlobalResearchState.COMPLETED
	global_research_elapsed[research_id] = config.duration_seconds
	active_global_research_id = &""
	_apply_global_bonuses()
	_bump_revision()
	_refresh_timer_state()
	research_milestone_changed.emit(0)


func try_purchase_player_technology(player: Player) -> StringName:
	if not authoritative_processing_enabled or player == null or player.is_dead:
		return RESULT_UNAVAILABLE
	if not player.supports_research_technology():
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
	var wire_states := {}
	var wire_elapsed := {}
	for config in GlobalResearchRegistry.get_all_configs():
		var wire_id := String(config.research_id)
		wire_states[wire_id] = int(get_global_research_state(config.research_id))
		wire_elapsed[wire_id] = get_global_elapsed_seconds(config.research_id)
	return {
		"schema": RUNTIME_STATE_SCHEMA,
		"revision": research_revision,
		"active_global_research_id": String(active_global_research_id),
		"global_states": wire_states,
		"global_elapsed": wire_elapsed,
		"player_levels": player_technology_levels.duplicate(),
	}


## 只读解码并冻结一份权威研究账本。地下探索外层全快照会先预检研究、
## 命运、成长与路线经济，任一领域无效时都不能先发布默认属性的玩家。
func prepare_multiplayer_runtime_state(
	state: Dictionary,
	allow_equal_authority_repair: bool = false
) -> Dictionary:
	if (
		state.is_empty()
		or typeof(state.get("schema")) != TYPE_INT
		or int(state["schema"]) != RUNTIME_STATE_SCHEMA
		or typeof(state.get("revision")) != TYPE_INT
		or typeof(state.get("active_global_research_id"))
		not in [TYPE_STRING, TYPE_STRING_NAME]
		or typeof(state.get("global_states")) != TYPE_DICTIONARY
		or typeof(state.get("global_elapsed")) != TYPE_DICTIONARY
		or typeof(state.get("player_levels")) != TYPE_DICTIONARY
	):
		return {}
	var incoming_revision := int(state["revision"])
	if incoming_revision < 0:
		return {}
	var active_wire_id := String(state["active_global_research_id"])
	var active_config := (
		GlobalResearchRegistry.get_config_by_wire_id(active_wire_id)
		if not active_wire_id.is_empty()
		else null
	)
	if not active_wire_id.is_empty() and active_config == null:
		return {}

	var incoming_states := state["global_states"] as Dictionary
	var incoming_elapsed := state["global_elapsed"] as Dictionary
	var registered_config_count := GlobalResearchRegistry.get_all_configs().size()
	if (
		incoming_states.size() != registered_config_count
		or incoming_elapsed.size() != registered_config_count
	):
		return {}
	var normalized_states := {}
	var normalized_elapsed := {}
	var researching_count := 0
	for config in GlobalResearchRegistry.get_all_configs():
		var wire_id := String(config.research_id)
		if (
			not incoming_states.has(wire_id)
			or not incoming_elapsed.has(wire_id)
			or typeof(incoming_states[wire_id]) != TYPE_INT
			or typeof(incoming_elapsed[wire_id]) not in [TYPE_INT, TYPE_FLOAT]
		):
			return {}
		var research_state := int(incoming_states[wire_id])
		var elapsed := float(incoming_elapsed[wire_id])
		if (
			research_state < GlobalResearchState.AVAILABLE
			or research_state > GlobalResearchState.COMPLETED
			or not is_finite(elapsed)
			or elapsed < 0.0
			or elapsed > config.duration_seconds + 0.0001
		):
			return {}
		match research_state:
			GlobalResearchState.AVAILABLE:
				if elapsed > 0.0001:
					return {}
			GlobalResearchState.RESEARCHING:
				if elapsed + 0.0001 >= config.duration_seconds:
					return {}
			GlobalResearchState.COMPLETED:
				if absf(elapsed - config.duration_seconds) > 0.0001:
					return {}
		if research_state == GlobalResearchState.RESEARCHING:
			researching_count += 1
			if active_config == null or active_config.research_id != config.research_id:
				return {}
		elif active_config != null and active_config.research_id == config.research_id:
			return {}
		normalized_states[config.research_id] = research_state
		normalized_elapsed[config.research_id] = clampf(
			elapsed,
			0.0,
			config.duration_seconds
		)
	if researching_count != (1 if active_config != null else 0):
		return {}

	var incoming_levels := state["player_levels"] as Dictionary
	if incoming_levels.size() > MAX_MULTIPLAYER_PLAYER_LEVEL_ENTRIES:
		return {}
	var normalized_levels := {}
	for player_key_variant in incoming_levels:
		var level_variant: Variant = incoming_levels[player_key_variant]
		if (
			typeof(player_key_variant) != TYPE_INT
			or typeof(level_variant) != TYPE_INT
			or int(player_key_variant) < 0
			or int(level_variant) < 0
			or int(level_variant) > Player.RESEARCH_TECHNOLOGY_MAX_LEVEL
		):
			return {}
		normalized_levels[int(player_key_variant)] = int(level_variant)

	var normalized_active_id := (
		active_config.research_id if active_config != null else &""
	)
	var values_changed := (
		normalized_states != global_research_states
		or normalized_elapsed != global_research_elapsed
		or normalized_active_id != active_global_research_id
		or normalized_levels != player_technology_levels
	)
	if (
		has_remote_snapshot
		and incoming_revision == research_revision
		and values_changed
		and not allow_equal_authority_repair
	):
		return {}
	return {
		"expected_has_remote_snapshot": has_remote_snapshot,
		"expected_revision": research_revision,
		"incoming_revision": incoming_revision,
		"active_global_research_id": normalized_active_id,
		"global_states": normalized_states,
		"global_elapsed": normalized_elapsed,
		"player_levels": normalized_levels,
		"stale": has_remote_snapshot and incoming_revision < research_revision,
		"changed": (
			values_changed
			or incoming_revision != research_revision
			or not has_remote_snapshot
		),
	}


## 预检之后只做不会失败的账本替换；expected revision 把同一帧内的准备与
## 提交锁成一个 CAS，避免路线经济与另一代研究状态混合。
func commit_prepared_multiplayer_runtime_state(prepared: Dictionary) -> bool:
	if not can_commit_prepared_multiplayer_runtime_state(prepared):
		return false
	commit_validated_multiplayer_runtime_state(prepared, true)
	return true


## 外层全快照已统一完成 CAS 后只替换研究账本；世界/Player 投影与信号
## 可以延迟到其他永久域和路线身份都提交完成后再发布。
func commit_validated_multiplayer_runtime_state(
	prepared: Dictionary,
	publish_changes: bool = true
) -> void:
	var incoming_revision := int(prepared["incoming_revision"])
	if bool(prepared["stale"]):
		return
	if not bool(prepared["changed"]):
		return
	has_remote_snapshot = true
	research_revision = incoming_revision
	global_research_states = (
		prepared["global_states"] as Dictionary
	).duplicate(true)
	global_research_elapsed = (
		prepared["global_elapsed"] as Dictionary
	).duplicate(true)
	active_global_research_id = StringName(
		prepared["active_global_research_id"]
	)
	player_technology_levels = (
		prepared["player_levels"] as Dictionary
	).duplicate(true)
	if publish_changes:
		publish_prepared_multiplayer_runtime_state(prepared)


func publish_prepared_multiplayer_runtime_state(prepared: Dictionary) -> void:
	if bool(prepared["stale"]) or not bool(prepared["changed"]):
		return
	_apply_global_bonuses()
	_apply_player_levels_to_runtime()
	_refresh_timer_state()
	research_state_changed.emit()


func can_commit_prepared_multiplayer_runtime_state(
	prepared: Dictionary
) -> bool:
	if (
		prepared.size() != 9
		or typeof(prepared.get("expected_has_remote_snapshot")) != TYPE_BOOL
		or typeof(prepared.get("expected_revision")) != TYPE_INT
		or typeof(prepared.get("incoming_revision")) != TYPE_INT
		or typeof(prepared.get("active_global_research_id")) != TYPE_STRING_NAME
		or typeof(prepared.get("global_states")) != TYPE_DICTIONARY
		or typeof(prepared.get("global_elapsed")) != TYPE_DICTIONARY
		or typeof(prepared.get("player_levels")) != TYPE_DICTIONARY
		or typeof(prepared.get("stale")) != TYPE_BOOL
		or typeof(prepared.get("changed")) != TYPE_BOOL
		or bool(prepared["expected_has_remote_snapshot"]) != has_remote_snapshot
		or int(prepared["expected_revision"]) != research_revision
	):
		return false
	var incoming_revision := int(prepared["incoming_revision"])
	if bool(prepared["stale"]):
		return has_remote_snapshot and incoming_revision < research_revision
	return incoming_revision >= research_revision


## 返回值表示权威研究账本是否已收敛；旧 revision 幂等接受，同 revision
## 内容冲突或协议无效则明确拒绝，供上层可靠结果信封触发完整修复。
func apply_multiplayer_runtime_state(state: Dictionary) -> bool:
	return commit_prepared_multiplayer_runtime_state(
		prepare_multiplayer_runtime_state(state)
	)


func _get_player_key(player: Player) -> int:
	return player.peer_id if player.peer_id > 0 else 0


func _apply_global_bonuses() -> void:
	if plant_system != null:
		plant_system.set_global_physical_defense_bonus(
			roundi(_get_completed_global_effect_total(
				GlobalResearchConfig.EffectType.BUILDING_PHYSICAL_DEFENSE
			))
		)
		plant_system.set_global_water_collector_duration_multiplier(
			get_water_collector_duration_multiplier()
		)
		plant_system.set_global_fence_max_health_bonus(
			get_fence_max_health_bonus()
		)
		plant_system.set_global_fence_physical_defense_bonus(
			get_fence_physical_defense_bonus()
		)
	_apply_global_player_bonus_to_registered_players()


func _apply_global_player_bonus_to_registered_players() -> void:
	var move_speed_bonus := _get_completed_global_effect_total(
		GlobalResearchConfig.EffectType.PLAYER_MOVE_SPEED
	)
	for key_variant in registered_players.keys():
		var key := int(key_variant)
		var player_ref := registered_players.get(key) as WeakRef
		var player := player_ref.get_ref() as Player if player_ref != null else null
		if player == null or not is_instance_valid(player):
			registered_players.erase(key)
			continue
		player.set_research_global_move_speed_bonus(move_speed_bonus)


func _apply_research_state_to_player(player: Player, technology_level: int) -> void:
	player.set_research_technology_level(technology_level)
	player.set_research_global_move_speed_bonus(
		_get_completed_global_effect_total(
			GlobalResearchConfig.EffectType.PLAYER_MOVE_SPEED
		)
	)


func _get_completed_global_effect_total(
	effect_type: GlobalResearchConfig.EffectType
) -> float:
	var total := 0.0
	for config in GlobalResearchRegistry.get_all_configs():
		if (
			config.effect_type == effect_type
			and get_global_research_state(config.research_id)
			== GlobalResearchState.COMPLETED
		):
			total += config.effect_amount
	return total


func _get_completed_global_secondary_effect_total(
	effect_type: GlobalResearchConfig.EffectType
) -> float:
	var total := 0.0
	for config in GlobalResearchRegistry.get_all_configs():
		if (
			config.effect_type == effect_type
			and get_global_research_state(config.research_id)
			== GlobalResearchState.COMPLETED
		):
			total += config.secondary_effect_amount
	return total


func _apply_player_levels_to_runtime() -> void:
	for key_variant in registered_players.keys():
		var key := int(key_variant)
		var player_ref := registered_players.get(key) as WeakRef
		var player := player_ref.get_ref() as Player if player_ref != null else null
		if player == null or not is_instance_valid(player):
			registered_players.erase(key)
			continue
		_apply_research_state_to_player(
			player,
			int(player_technology_levels.get(key, 0))
		)
	if player_roster_coordinator == null:
		return
	if (
		player_roster_coordinator.runtime_mode
		== CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	):
		if player_roster_coordinator.local_player != null:
			register_player(player_roster_coordinator.local_player)
		return
	for key_variant in player_technology_levels:
		var key := int(key_variant)
		var player := player_roster_coordinator.get_player(key)
		if player != null:
			register_player(player)


func _bump_revision() -> void:
	research_revision += 1
	research_state_changed.emit()


func _on_research_tick() -> void:
	if authoritative_processing_enabled:
		advance_global_research(research_tick_timer.wait_time)
	elif not active_global_research_id.is_empty():
		var config := GlobalResearchRegistry.get_config(active_global_research_id)
		if config == null:
			return
		global_research_elapsed[active_global_research_id] = minf(
			get_global_elapsed_seconds(active_global_research_id)
				+ research_tick_timer.wait_time,
			config.duration_seconds
		)
		research_state_changed.emit()


func _refresh_timer_state() -> void:
	if not is_node_ready():
		return
	var should_run := (
		not active_global_research_id.is_empty()
		and (
			get_global_research_state(active_global_research_id)
			== GlobalResearchState.RESEARCHING
		)
	)
	if should_run and research_tick_timer.is_stopped():
		research_tick_timer.start()
	elif not should_run and not research_tick_timer.is_stopped():
		research_tick_timer.stop()
