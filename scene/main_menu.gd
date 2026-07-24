extends Control

const GAME_SCENE_PATH := "res://scene/game.tscn"
const GAME_TOWER_DEFENSE_SCENE_PATH := "res://scene/game_tower_defense.tscn"
const TEST_GRASS_ARENA_SCENE_PATH := (
	"res://scene/test_arena/test_grass_arena.tscn"
)

enum SingleplayerDestination {
	STANDARD,
	TOWER_DEFENSE,
	TEST_ARENA,
}

@onready var settings_panel: Control = $SettingsPanel
@onready var singleplayer_button: Button = $MenuCenter/MenuPanel/MarginContainer/MenuStack/SinglePlayer
@onready var tower_defense_button: Button = $MenuCenter/MenuPanel/MarginContainer/MenuStack/TowerDefense
@onready var test_arena_button: Button = $MenuCenter/MenuPanel/MarginContainer/MenuStack/TestArena
@onready var character_choice_overlay: PlayerCharacterChoiceOverlay = $PlayerCharacterChoiceOverlay

var pending_singleplayer_destination := SingleplayerDestination.STANDARD


func _ready() -> void:
	character_choice_overlay.character_confirmed.connect(_on_character_confirmed)
	character_choice_overlay.selection_closed.connect(_on_character_selection_closed)


func _on_singleplayer_pressed() -> void:
	_open_singleplayer_character_selection(SingleplayerDestination.STANDARD)


func _on_tower_defense_pressed() -> void:
	_open_singleplayer_character_selection(SingleplayerDestination.TOWER_DEFENSE)


func _on_test_arena_pressed() -> void:
	_open_singleplayer_character_selection(SingleplayerDestination.TEST_ARENA)


func _open_singleplayer_character_selection(destination: SingleplayerDestination) -> void:
	pending_singleplayer_destination = destination
	var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore
	character_choice_overlay.open(run_state.get_selected_character_id())


func _on_character_confirmed(character_id: StringName) -> void:
	var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore
	if not run_state.set_selected_character(character_id):
		push_error("Main menu received an invalid character selection: %s" % character_id)
		return
	run_state.begin_new_run(character_id)
	var load_coordinator := get_node_or_null("/root/GameLoadCoordinator")
	if load_coordinator != null and load_coordinator.has_method("begin_singleplayer"):
		load_coordinator.call("begin_singleplayer", _get_pending_singleplayer_scene_path())
		return
	get_tree().change_scene_to_file(_get_pending_singleplayer_scene_path())


func _get_pending_singleplayer_scene_path() -> String:
	match pending_singleplayer_destination:
		SingleplayerDestination.TOWER_DEFENSE:
			return GAME_TOWER_DEFENSE_SCENE_PATH
		SingleplayerDestination.TEST_ARENA:
			return TEST_GRASS_ARENA_SCENE_PATH
		_:
			return GAME_SCENE_PATH


func _on_character_selection_closed() -> void:
	match pending_singleplayer_destination:
		SingleplayerDestination.TOWER_DEFENSE:
			tower_defense_button.grab_focus()
		SingleplayerDestination.TEST_ARENA:
			test_arena_button.grab_focus()
		_:
			singleplayer_button.grab_focus()


func _on_multiplayer_pressed() -> void:
	get_tree().change_scene_to_file("res://scene/multiplayer/multiplayer_lobby.tscn")


func _on_settings_pressed() -> void:
	if settings_panel != null and settings_panel.has_method("open"):
		settings_panel.call("open")


func _on_quit_pressed() -> void:
	get_tree().quit()
