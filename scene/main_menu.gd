extends Control

const GAME_SCENE_PATH := "res://scene/game.tscn"
const GAME_TOWER_DEFENSE_SCENE_PATH := "res://scene/game_tower_defense.tscn"
const TEST_GRASS_ARENA_SCENE_PATH := (
	"res://scene/test_arena/test_grass_arena.tscn"
)
const TEST_GRASS_ARENA_P2_SCENE_PATH := (
	"res://scene/test_arena/test_grass_arena_p2.tscn"
)
const TEST_ARENA_P1_ID := &"p1"
const TEST_ARENA_P2_ID := &"p2"
const TEST_ARENA_SCENE_PATHS := {
	TEST_ARENA_P1_ID: TEST_GRASS_ARENA_SCENE_PATH,
	TEST_ARENA_P2_ID: TEST_GRASS_ARENA_P2_SCENE_PATH,
}

enum SingleplayerDestination {
	STANDARD,
	TOWER_DEFENSE,
	TEST_ARENA,
}

@onready var settings_panel: Control = $SettingsPanel
@onready var singleplayer_button: Button = $MenuCenter/MenuPanel/MarginContainer/MenuStack/SinglePlayer
@onready var tower_defense_button: Button = $MenuCenter/MenuPanel/MarginContainer/MenuStack/TowerDefense
@onready var test_arena_button: Button = $MenuCenter/MenuPanel/MarginContainer/MenuStack/TestArena
@onready var test_arena_choice_overlay: TestArenaChoiceOverlay = $TestArenaChoiceOverlay
@onready var character_choice_overlay: PlayerCharacterChoiceOverlay = $PlayerCharacterChoiceOverlay

var pending_singleplayer_destination := SingleplayerDestination.STANDARD
var pending_test_arena_id: StringName = TEST_ARENA_P1_ID


func _ready() -> void:
	test_arena_choice_overlay.arena_selected.connect(_on_test_arena_selected)
	test_arena_choice_overlay.selection_closed.connect(_on_test_arena_selection_closed)
	character_choice_overlay.character_confirmed.connect(_on_character_confirmed)
	character_choice_overlay.selection_closed.connect(_on_character_selection_closed)


func _on_singleplayer_pressed() -> void:
	_open_singleplayer_character_selection(SingleplayerDestination.STANDARD)


func _on_tower_defense_pressed() -> void:
	_open_singleplayer_character_selection(SingleplayerDestination.TOWER_DEFENSE)


func _on_test_arena_pressed() -> void:
	test_arena_choice_overlay.open(pending_test_arena_id)


func _on_test_arena_selected(arena_id: StringName) -> void:
	if not TEST_ARENA_SCENE_PATHS.has(arena_id):
		push_error("Main menu received an invalid test arena: %s" % arena_id)
		return
	pending_test_arena_id = arena_id
	_open_singleplayer_character_selection(SingleplayerDestination.TEST_ARENA)


func _on_test_arena_selection_closed() -> void:
	test_arena_button.grab_focus()


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
			return str(
				TEST_ARENA_SCENE_PATHS.get(
					pending_test_arena_id,
					TEST_GRASS_ARENA_SCENE_PATH
				)
			)
		_:
			return GAME_SCENE_PATH


func _on_character_selection_closed() -> void:
	match pending_singleplayer_destination:
		SingleplayerDestination.TOWER_DEFENSE:
			tower_defense_button.grab_focus()
		SingleplayerDestination.TEST_ARENA:
			test_arena_choice_overlay.open(pending_test_arena_id)
		_:
			singleplayer_button.grab_focus()


func _on_multiplayer_pressed() -> void:
	get_tree().change_scene_to_file("res://scene/multiplayer/multiplayer_lobby.tscn")


func _on_settings_pressed() -> void:
	if settings_panel != null and settings_panel.has_method("open"):
		settings_panel.call("open")


func _on_quit_pressed() -> void:
	get_tree().quit()
