extends Control
class_name MainMenu

const ENCYCLOPEDIA_SCENE_PATH := "res://scene/encyclopedia/encyclopedia_screen.tscn"
const TEST_ARENA_P1A_ID := &"p1"
const TEST_ARENA_P1_ID := TEST_ARENA_P1A_ID
const TEST_ARENA_P1B_ID := &"p1b"
const TEST_ARENA_P1C_ID := &"p1c"
const TEST_ARENA_P1D_ID := &"p1d"
const TEST_ARENA_P1E_ID := &"p1e"
const TEST_ARENA_P2_ID := &"p2"
const TEST_ARENA_P3_ID := &"p3"
const TEST_ARENA_MODE_IDS := {
	TEST_ARENA_P1A_ID: GameModeCatalog.MODE_TEST_ARENA_P1,
	TEST_ARENA_P1B_ID: GameModeCatalog.MODE_TEST_ARENA_P1B,
	TEST_ARENA_P1C_ID: GameModeCatalog.MODE_TEST_ARENA_P1C,
	TEST_ARENA_P1D_ID: GameModeCatalog.MODE_TEST_ARENA_P1D,
	TEST_ARENA_P1E_ID: GameModeCatalog.MODE_TEST_ARENA_P1E,
	TEST_ARENA_P2_ID: GameModeCatalog.MODE_TEST_ARENA_P2,
	TEST_ARENA_P3_ID: GameModeCatalog.MODE_TEST_ARENA_P3,
}
const FOCUS_DEFAULT: StringName = &"singleplayer"
const FOCUS_ENCYCLOPEDIA: StringName = &"encyclopedia"
const ENCYCLOPEDIA_LOADING_TEXT := "正在整理图鉴…"
const ENCYCLOPEDIA_LOAD_FAILED_TEXT := "图鉴整理失败，请再次尝试"
const FEEDBACK_LOADING_COLOR := Color("78d8c3")
const FEEDBACK_ERROR_COLOR := Color("e5b96b")
const FEEDBACK_FADE_DURATION := 0.12
const COLLECTIBLE_PRELOAD_MAX_IN_FLIGHT := 8
const COLLECTIBLE_PRELOAD_STARTS_PER_FRAME := 8

enum EncyclopediaLoadState {
	IDLE,
	LOADING,
	LOADED,
	TRANSITIONING,
	FAILED,
}

enum SingleplayerDestination {
	STANDARD,
	TOWER_DEFENSE,
	ROGUE,
	TEST_ARENA,
}

@onready var settings_panel: Control = $SettingsPanel
@onready var singleplayer_button: Button = $MenuCenter/MenuPanel/MarginContainer/MenuStack/SinglePlayer
@onready var tower_defense_button: Button = $MenuCenter/MenuPanel/MarginContainer/MenuStack/TowerDefense
@onready var rogue_button: Button = $MenuCenter/MenuPanel/MarginContainer/MenuStack/Rogue
@onready var test_arena_button: Button = $MenuCenter/MenuPanel/MarginContainer/MenuStack/TestArena
@onready var multiplayer_button: Button = $MenuCenter/MenuPanel/MarginContainer/MenuStack/Multiplayer
@onready var encyclopedia_button: Button = $MenuCenter/MenuPanel/MarginContainer/MenuStack/Encyclopedia
@onready var test_arena_choice_overlay: TestArenaChoiceOverlay = $TestArenaChoiceOverlay
@onready var character_choice_overlay: PlayerCharacterChoiceOverlay = $PlayerCharacterChoiceOverlay
@onready var encyclopedia_loading_feedback: PanelContainer = $EncyclopediaLoadingFeedback
@onready var encyclopedia_loading_label: Label = $EncyclopediaLoadingFeedback/Status

static var _requested_focus_id: StringName = FOCUS_DEFAULT

var pending_singleplayer_destination := SingleplayerDestination.STANDARD
var pending_test_arena_id: StringName = TEST_ARENA_P1A_ID
var _encyclopedia_load_state := EncyclopediaLoadState.IDLE
var _encyclopedia_scene: PackedScene
var _encyclopedia_open_requested := false
var _encyclopedia_feedback_tween: Tween
var _is_exiting_tree := false
var _collectible_config_paths: Array[String] = []
var _collectible_next_request_index := 0
var _collectible_loading_paths: Dictionary = {}


func _ready() -> void:
	set_process(false)
	_configure_main_menu_visibility()
	test_arena_choice_overlay.arena_selected.connect(_on_test_arena_selected)
	test_arena_choice_overlay.selection_closed.connect(_on_test_arena_selection_closed)
	character_choice_overlay.character_confirmed.connect(_on_character_confirmed)
	character_choice_overlay.selection_closed.connect(_on_character_selection_closed)
	call_deferred("_apply_requested_focus")
	call_deferred("_preload_encyclopedia_after_first_frame")


func _configure_main_menu_visibility() -> void:
	# 测试场只属于调试构建；正式菜单始终形成 Standard/Tower/Rogue 三入口。
	var show_development_entries := OS.is_debug_build()
	test_arena_button.visible = show_development_entries
	rogue_button.focus_neighbor_bottom = (
		rogue_button.get_path_to(test_arena_button)
		if show_development_entries
		else rogue_button.get_path_to(multiplayer_button)
	)
	multiplayer_button.focus_neighbor_top = (
		multiplayer_button.get_path_to(test_arena_button)
		if show_development_entries
		else multiplayer_button.get_path_to(rogue_button)
	)


func _exit_tree() -> void:
	_is_exiting_tree = true
	_encyclopedia_open_requested = false
	set_process(false)
	_collectible_config_paths.clear()
	_collectible_next_request_index = 0
	_collectible_loading_paths.clear()
	if _encyclopedia_feedback_tween != null:
		_encyclopedia_feedback_tween.kill()


func _process(_delta: float) -> void:
	if _encyclopedia_load_state == EncyclopediaLoadState.LOADING:
		_poll_encyclopedia_preload()


func _unhandled_input(event: InputEvent) -> void:
	if (
		event.is_action_pressed("ui_cancel")
		and (
			(
				_encyclopedia_open_requested
				and _encyclopedia_load_state != EncyclopediaLoadState.TRANSITIONING
			)
			or (
				_encyclopedia_load_state == EncyclopediaLoadState.FAILED
				and encyclopedia_loading_feedback.visible
			)
		)
	):
		_cancel_pending_encyclopedia_open()
		encyclopedia_button.grab_focus()
		get_viewport().set_input_as_handled()


static func request_focus_after_return(focus_id: StringName) -> void:
	_requested_focus_id = focus_id


func _apply_requested_focus() -> void:
	var target := (
		encyclopedia_button
		if _requested_focus_id == FOCUS_ENCYCLOPEDIA
		else singleplayer_button
	)
	_requested_focus_id = FOCUS_DEFAULT
	if target != null and target.is_visible_in_tree() and not target.disabled:
		target.grab_focus()


func _on_singleplayer_pressed() -> void:
	_cancel_pending_encyclopedia_open()
	_open_singleplayer_character_selection(SingleplayerDestination.STANDARD)


func _on_tower_defense_pressed() -> void:
	_cancel_pending_encyclopedia_open()
	_open_singleplayer_character_selection(SingleplayerDestination.TOWER_DEFENSE)


func _on_rogue_pressed() -> void:
	_cancel_pending_encyclopedia_open()
	_open_singleplayer_character_selection(SingleplayerDestination.ROGUE)


func _on_test_arena_pressed() -> void:
	_cancel_pending_encyclopedia_open()
	test_arena_choice_overlay.open(pending_test_arena_id)


func _on_test_arena_selected(arena_id: StringName) -> void:
	if not TEST_ARENA_MODE_IDS.has(arena_id):
		push_error("Main menu received an invalid test arena: %s" % arena_id)
		return
	var mode_id := int(TEST_ARENA_MODE_IDS[arena_id])
	if not GameModeCatalog.is_development_selectable(mode_id):
		push_warning("Main menu rejected an unpublished test arena: %s" % arena_id)
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
	var definition := _get_pending_singleplayer_definition()
	var selection_audience := (
		GameModeDefinition.SelectionAudience.DEVELOPMENT
		if pending_singleplayer_destination == SingleplayerDestination.TEST_ARENA
		else GameModeDefinition.SelectionAudience.RELEASE
	)
	if (
		definition == null
		or not definition.is_selectable_for(selection_audience)
	):
		push_error("Main menu could not resolve the selected game mode.")
		return
	run_state.begin_new_run(character_id, definition.include_starting_inventory)
	_begin_singleplayer_load(
		definition.singleplayer_entry_scene_path,
		selection_audience
	)


func _begin_singleplayer_load(
	scene_path: String,
	selection_audience: GameModeDefinition.SelectionAudience = (
		GameModeDefinition.SelectionAudience.RELEASE
	)
) -> void:
	var definition := GameModeCatalog.get_definition_by_singleplayer_entry(
		scene_path
	)
	if (
		definition == null
		or not definition.is_selectable_for(selection_audience)
	):
		push_warning("Main menu rejected an unpublished singleplayer scene: %s" % scene_path)
		return
	var load_coordinator := get_node_or_null("/root/GameLoadCoordinator")
	if load_coordinator != null and load_coordinator.has_method("begin_singleplayer"):
		load_coordinator.call("begin_singleplayer", scene_path, selection_audience)
		return
	get_tree().change_scene_to_file(scene_path)


func _get_pending_singleplayer_scene_path() -> String:
	var definition := _get_pending_singleplayer_definition()
	return definition.singleplayer_entry_scene_path if definition != null else ""


func _get_pending_singleplayer_definition() -> GameModeDefinition:
	return GameModeCatalog.get_definition(_get_pending_singleplayer_mode_id())


func _get_pending_singleplayer_mode_id() -> int:
	match pending_singleplayer_destination:
		SingleplayerDestination.TOWER_DEFENSE:
			return GameModeCatalog.MODE_TOWER_DEFENSE
		SingleplayerDestination.ROGUE:
			return GameModeCatalog.MODE_ROGUE
		SingleplayerDestination.TEST_ARENA:
			return int(
				TEST_ARENA_MODE_IDS.get(
					pending_test_arena_id,
					GameModeCatalog.MODE_TEST_ARENA_P1
				)
			)
		_:
			return GameModeCatalog.MODE_STANDARD


func _on_character_selection_closed() -> void:
	match pending_singleplayer_destination:
		SingleplayerDestination.TOWER_DEFENSE:
			tower_defense_button.grab_focus()
		SingleplayerDestination.ROGUE:
			rogue_button.grab_focus()
		SingleplayerDestination.TEST_ARENA:
			test_arena_choice_overlay.open(pending_test_arena_id)
		_:
			singleplayer_button.grab_focus()


func _on_multiplayer_pressed() -> void:
	_cancel_pending_encyclopedia_open()
	get_tree().change_scene_to_file("res://scene/multiplayer/multiplayer_lobby.tscn")


func _on_encyclopedia_pressed() -> void:
	if (
		_encyclopedia_open_requested
		or _encyclopedia_load_state == EncyclopediaLoadState.TRANSITIONING
	):
		return
	_encyclopedia_open_requested = true
	if _encyclopedia_load_state == EncyclopediaLoadState.LOADED:
		call_deferred("_enter_loaded_encyclopedia")
		return
	_show_encyclopedia_feedback(ENCYCLOPEDIA_LOADING_TEXT, false)
	_ensure_encyclopedia_preload_started()


func _on_settings_pressed() -> void:
	_cancel_pending_encyclopedia_open()
	if settings_panel != null and settings_panel.has_method("open"):
		settings_panel.call("open")


func _on_quit_pressed() -> void:
	_cancel_pending_encyclopedia_open()
	get_tree().quit()


func _preload_encyclopedia_after_first_frame() -> void:
	await get_tree().process_frame
	if _is_exiting_tree or not is_inside_tree():
		return
	_ensure_encyclopedia_preload_started()


func _ensure_encyclopedia_preload_started() -> void:
	if (
		_is_exiting_tree
		or _encyclopedia_load_state == EncyclopediaLoadState.LOADING
		or _encyclopedia_load_state == EncyclopediaLoadState.LOADED
		or _encyclopedia_load_state == EncyclopediaLoadState.TRANSITIONING
	):
		return

	var existing_status := ResourceLoader.load_threaded_get_status(
		ENCYCLOPEDIA_SCENE_PATH
	)
	match existing_status:
		ResourceLoader.THREAD_LOAD_LOADED:
			_encyclopedia_load_state = EncyclopediaLoadState.LOADING
			set_process(true)
			_finish_encyclopedia_scene_preload()
			return
		ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			_encyclopedia_load_state = EncyclopediaLoadState.LOADING
			set_process(true)
			return

	var cache_mode := ResourceLoader.CACHE_MODE_REUSE
	if existing_status == ResourceLoader.THREAD_LOAD_FAILED:
		cache_mode = ResourceLoader.CACHE_MODE_REPLACE
	var error := ResourceLoader.load_threaded_request(
		ENCYCLOPEDIA_SCENE_PATH,
		"PackedScene",
		false,
		cache_mode
	)
	if error != OK:
		_fail_encyclopedia_preload(
			"无法开始加载图鉴：%s" % error_string(error)
		)
		return
	_encyclopedia_load_state = EncyclopediaLoadState.LOADING
	set_process(true)


func _poll_encyclopedia_preload() -> void:
	if _encyclopedia_scene != null:
		_poll_collectible_cache_warmup()
		return
	var status := ResourceLoader.load_threaded_get_status(
		ENCYCLOPEDIA_SCENE_PATH
	)
	match status:
		ResourceLoader.THREAD_LOAD_LOADED:
			_finish_encyclopedia_scene_preload()
		ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			_fail_encyclopedia_preload("图鉴场景或其依赖资源加载失败")


func _finish_encyclopedia_scene_preload() -> void:
	# Only retrieve after LOADED. Calling load_threaded_get() any earlier would
	# block the main thread and recreate the menu freeze this path is designed to avoid.
	if (
		ResourceLoader.load_threaded_get_status(ENCYCLOPEDIA_SCENE_PATH)
		!= ResourceLoader.THREAD_LOAD_LOADED
	):
		_fail_encyclopedia_preload("图鉴加载状态异常，已停止进入")
		return
	_encyclopedia_load_state = EncyclopediaLoadState.LOADING
	set_process(true)
	var loaded_resource := ResourceLoader.load_threaded_get(
		ENCYCLOPEDIA_SCENE_PATH
	)
	_encyclopedia_scene = loaded_resource as PackedScene
	if _encyclopedia_scene == null:
		_fail_encyclopedia_preload("图鉴资源加载完成，但不是可实例化场景")
		return
	_begin_collectible_cache_warmup()


func _begin_collectible_cache_warmup() -> void:
	if CollectibleRegistry.is_cache_ready():
		_complete_encyclopedia_preload()
		return
	_collectible_config_paths = CollectibleRegistry.get_config_paths()
	_collectible_next_request_index = 0
	_collectible_loading_paths.clear()
	if _collectible_config_paths.is_empty():
		_fail_encyclopedia_preload("没有找到可供图鉴预热的收藏品配置")
		return
	_pump_collectible_cache_requests()


func _poll_collectible_cache_warmup() -> void:
	if CollectibleRegistry.is_cache_ready():
		_complete_encyclopedia_preload()
		return
	for path_variant in _collectible_loading_paths.keys():
		var path := str(path_variant)
		var status := ResourceLoader.load_threaded_get_status(path)
		match status:
			ResourceLoader.THREAD_LOAD_LOADED:
				if not _cache_loaded_collectible_config(path):
					return
				_collectible_loading_paths.erase(path)
			ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
				_fail_encyclopedia_preload("收藏品配置加载失败：%s" % path)
				return
	_pump_collectible_cache_requests()
	if _encyclopedia_load_state != EncyclopediaLoadState.LOADING:
		return
	if (
		_collectible_next_request_index < _collectible_config_paths.size()
		or not _collectible_loading_paths.is_empty()
	):
		return
	CollectibleRegistry.finish_cache_warmup()
	if not CollectibleRegistry.is_cache_ready():
		_fail_encyclopedia_preload("收藏品配置缓存未能完成初始化")
		return
	_complete_encyclopedia_preload()


func _pump_collectible_cache_requests() -> void:
	var started_this_frame := 0
	while (
		_encyclopedia_load_state == EncyclopediaLoadState.LOADING
		and _collectible_next_request_index < _collectible_config_paths.size()
		and _collectible_loading_paths.size() < COLLECTIBLE_PRELOAD_MAX_IN_FLIGHT
		and started_this_frame < COLLECTIBLE_PRELOAD_STARTS_PER_FRAME
	):
		var path := _collectible_config_paths[_collectible_next_request_index]
		_collectible_next_request_index += 1
		started_this_frame += 1
		var existing_status := ResourceLoader.load_threaded_get_status(path)
		match existing_status:
			ResourceLoader.THREAD_LOAD_LOADED:
				if not _cache_loaded_collectible_config(path):
					return
			ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				_collectible_loading_paths[path] = true
			_:
				var cache_mode := ResourceLoader.CACHE_MODE_REUSE
				if existing_status == ResourceLoader.THREAD_LOAD_FAILED:
					cache_mode = ResourceLoader.CACHE_MODE_REPLACE
				var error := ResourceLoader.load_threaded_request(
					path,
					"Resource",
					false,
					cache_mode
				)
				if error != OK:
					_fail_encyclopedia_preload(
						"无法开始加载收藏品配置：%s（%s）"
						% [path, error_string(error)]
					)
					return
				_collectible_loading_paths[path] = true


func _cache_loaded_collectible_config(path: String) -> bool:
	# The explicit status guard keeps every threaded get non-blocking, including
	# resources that were requested by an earlier MainMenu instance.
	if (
		ResourceLoader.load_threaded_get_status(path)
		!= ResourceLoader.THREAD_LOAD_LOADED
	):
		_fail_encyclopedia_preload("收藏品配置尚未完成加载：%s" % path)
		return false
	var config := ResourceLoader.load_threaded_get(path) as PickupConfig
	if config == null:
		_fail_encyclopedia_preload("收藏品配置类型无效：%s" % path)
		return false
	CollectibleRegistry.cache_config(config)
	return true


func _complete_encyclopedia_preload() -> void:
	if _encyclopedia_scene == null or not CollectibleRegistry.is_cache_ready():
		_fail_encyclopedia_preload("图鉴预热未完整完成，已停止进入")
		return
	_collectible_config_paths.clear()
	_collectible_next_request_index = 0
	_collectible_loading_paths.clear()
	_encyclopedia_load_state = EncyclopediaLoadState.LOADED
	set_process(false)
	if _encyclopedia_open_requested:
		call_deferred("_enter_loaded_encyclopedia")


func _fail_encyclopedia_preload(message: String) -> void:
	_encyclopedia_load_state = EncyclopediaLoadState.FAILED
	_encyclopedia_scene = null
	_collectible_config_paths.clear()
	_collectible_next_request_index = 0
	_collectible_loading_paths.clear()
	set_process(false)
	push_error(message)
	if not _encyclopedia_open_requested:
		return
	_encyclopedia_open_requested = false
	_show_encyclopedia_feedback(ENCYCLOPEDIA_LOAD_FAILED_TEXT, true)
	encyclopedia_button.call_deferred("grab_focus")


func _enter_loaded_encyclopedia() -> void:
	if (
		_is_exiting_tree
		or not _encyclopedia_open_requested
		or _encyclopedia_load_state != EncyclopediaLoadState.LOADED
		or _encyclopedia_scene == null
	):
		return
	_encyclopedia_open_requested = false
	_encyclopedia_load_state = EncyclopediaLoadState.TRANSITIONING
	_hide_encyclopedia_feedback()
	var error := get_tree().change_scene_to_packed(_encyclopedia_scene)
	if error == OK:
		return
	_encyclopedia_load_state = EncyclopediaLoadState.LOADED
	_show_encyclopedia_feedback(ENCYCLOPEDIA_LOAD_FAILED_TEXT, true)
	push_error("无法进入图鉴场景：%s" % error_string(error))
	encyclopedia_button.call_deferred("grab_focus")


func _cancel_pending_encyclopedia_open() -> void:
	_encyclopedia_open_requested = false
	if encyclopedia_loading_feedback.visible:
		_hide_encyclopedia_feedback()


func _show_encyclopedia_feedback(message: String, is_error: bool) -> void:
	encyclopedia_loading_label.text = message
	encyclopedia_loading_label.add_theme_color_override(
		"font_color",
		FEEDBACK_ERROR_COLOR if is_error else FEEDBACK_LOADING_COLOR
	)
	if _encyclopedia_feedback_tween != null:
		_encyclopedia_feedback_tween.kill()
	encyclopedia_loading_feedback.modulate.a = 0.0
	encyclopedia_loading_feedback.show()
	_encyclopedia_feedback_tween = create_tween()
	_encyclopedia_feedback_tween.set_trans(Tween.TRANS_QUAD)
	_encyclopedia_feedback_tween.set_ease(Tween.EASE_OUT)
	_encyclopedia_feedback_tween.tween_property(
		encyclopedia_loading_feedback,
		"modulate:a",
		1.0,
		FEEDBACK_FADE_DURATION
	)


func _hide_encyclopedia_feedback() -> void:
	if _encyclopedia_feedback_tween != null:
		_encyclopedia_feedback_tween.kill()
		_encyclopedia_feedback_tween = null
	encyclopedia_loading_feedback.hide()
