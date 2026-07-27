extends GameTowerDefense
class_name TestGrassArena

signal manual_day_night_changed(is_night: bool)

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
const FORMAL_PROGRESSION := preload(
	"res://resources/config/campaigns/tower_defense/formal_progression.tres"
)

@onready var test_controls_hint: Label = $TestControlsHint/Hint

var manual_night_enabled := false
var _nearby_plant_destroy_scratch: Array[PlantDefense] = []


func _ready() -> void:
	progression_config = FORMAL_PROGRESSION.duplicate(true)
	progression_config.initial_preparation_seconds = 1.0
	progression_config.wave_intermission_seconds = 1.0
	progression_config.new_day_preparation_seconds = 1.0
	super._ready()
	manual_night_enabled = false
	day_night_controller.set_night_factor_immediate(0.0)
	_update_test_controls_hint()


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
				_destroy_plants_near_player()
				get_viewport().set_input_as_handled()
				return
			KEY_L:
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
	manual_night_enabled = enabled
	if manual_night_enabled:
		day_night_controller.transition_to_night(duration_seconds)
	else:
		day_night_controller.transition_to_day(duration_seconds)
	_update_test_controls_hint()
	manual_day_night_changed.emit(manual_night_enabled)


func _update_test_controls_hint() -> void:
	test_controls_hint.text = (
		"草地测试场景｜当前：%s\n"
		+ "T：自由放置植物　L：切换昼夜　Del：摧毁周围3格植物"
	) % ("夜晚" if manual_night_enabled else "白天")
