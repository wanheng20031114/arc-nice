extends TowerDefenseGame
class_name TestGrassArena

const GRASS_RECT := Rect2i(0, 0, 16, 16)
const BLUE_GATE_CELLS: Array[Vector2i] = [
	Vector2i(0, 7),
	Vector2i(0, 8),
]
const RED_GATE_CELLS: Array[Vector2i] = [
	Vector2i(15, 7),
	Vector2i(15, 8),
]
const DEBUG_DESTROY_PLANT_RADIUS_CELLS := 3.0
const TEST_BASE_HEALTH := 1000
const FORMAL_PROGRESSION := preload(
	"res://resources/config/campaigns/tower_defense/formal_progression.tres"
)

@export var test_scene_label := "P1A"
@export var test_entry_announcement_text := "测试场景 P1A"
@export var test_environment_title := "草地测试场景"

@onready var test_controls_hint: Label = $TestControlsHint/Hint

var manual_night_enabled := false
var _nearby_plant_destroy_scratch: Array[PlantDefense] = []


func _ready() -> void:
	progression_config = FORMAL_PROGRESSION.duplicate(true)
	progression_config.initial_preparation_seconds = 3.0
	progression_config.wave_intermission_seconds = 1.0
	progression_config.new_day_preparation_seconds = 1.0
	progression_config.enemy_count_per_extra_player_ratio = 0.0
	campaign_coordinator.custom_first_wave_announcement_text = (
		test_entry_announcement_text
	)
	super._ready()
	manual_night_enabled = false
	day_night_controller.set_night_factor_immediate(0.0)
	_update_test_controls_hint()


## P1A/P1B 用于综合压力测试，扩大核心血量以避免长时间测试被过早中断。
func _configure_home_defense() -> void:
	super._configure_home_defense()
	maximum_base_health = TEST_BASE_HEALTH
	current_base_health = TEST_BASE_HEALTH
	_update_base_health_display(false)


## 测试场景的昼夜只接受玩家手动控制，忽略正式流程的自动入夜请求。
func transition_world_to_night(_duration_seconds: float = -1.0) -> void:
	pass


## 测试场景的昼夜只接受玩家手动控制，忽略正式流程的自动回昼请求。
func transition_world_to_day(_duration_seconds: float = -1.0) -> void:
	pass


func _unhandled_input(event: InputEvent) -> void:
	var key_event := event as InputEventKey
	if (
		key_event != null
		and key_event.pressed
		and not key_event.echo
	):
		match key_event.physical_keycode:
			KEY_DELETE:
				if runtime_mode != RuntimeMode.CLIENT_VIEW:
					_destroy_plants_near_player()
				get_viewport().set_input_as_handled()
				return
			KEY_L:
				if runtime_mode != RuntimeMode.CLIENT_VIEW:
					set_manual_night_enabled(not manual_night_enabled)
				get_viewport().set_input_as_handled()
				return
	super._unhandled_input(event)


func _destroy_plants_near_player() -> int:
	if (
		runtime_mode == RuntimeMode.CLIENT_VIEW
		or player == null
		or not is_instance_valid(player)
		or plant_system == null
	):
		return 0
	plant_system.query_living_plants_in_logical_radius_into(
		player.global_position,
		DEBUG_DESTROY_PLANT_RADIUS_CELLS,
		_nearby_plant_destroy_scratch
	)
	var destroyed_count := 0
	for plant in _nearby_plant_destroy_scratch:
		if (
			plant == null
			or not is_instance_valid(plant)
			or plant.is_dead
			or plant.is_removing
		):
			continue
		if plant.receive_unmitigated_damage(plant.current_health, player):
			destroyed_count += 1
	_nearby_plant_destroy_scratch.clear()
	return destroyed_count


func set_manual_night_enabled(
	enabled: bool,
	duration_seconds: float = -1.0
) -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	_apply_manual_night_enabled(enabled, duration_seconds)
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		tower_multiplayer_mode_adapter.test_arena_manual_night_changed.emit(manual_night_enabled)


func supports_test_arena_manual_night_sync() -> bool:
	return true


func get_test_arena_manual_night_enabled() -> bool:
	return manual_night_enabled


func apply_remote_test_arena_manual_night(enabled: bool) -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		return
	_apply_manual_night_enabled(enabled)


func _apply_manual_night_enabled(
	enabled: bool,
	duration_seconds: float = -1.0
) -> void:
	manual_night_enabled = enabled
	if manual_night_enabled:
		day_night_controller.transition_to_night(duration_seconds)
	else:
		day_night_controller.transition_to_day(duration_seconds)
	_update_test_controls_hint()


func _update_test_controls_hint() -> void:
	var controls_text := (
		"T：自由放置植物　L：切换昼夜　Del：摧毁周围3格植物"
		if runtime_mode == RuntimeMode.SINGLEPLAYER
		else (
			"T：自由放置植物　L/Del：仅房主可用"
			if runtime_mode == RuntimeMode.CLIENT_VIEW
			else "T：自由放置植物　L：切换昼夜（房主）　Del：摧毁周围3格植物（房主）"
		)
	)
	test_controls_hint.text = (
		"%s %s｜当前：%s\n"
		+ controls_text
	) % [
		test_environment_title,
		test_scene_label,
		"夜晚" if manual_night_enabled else "白天",
	]
