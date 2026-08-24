extends CanvasLayer
class_name TestArenaChoiceOverlay

signal arena_selected(arena_id: StringName)
signal selection_closed

const ARENA_P1A_ID: StringName = &"p1"
const ARENA_P1_ID: StringName = ARENA_P1A_ID
const ARENA_P1B_ID: StringName = &"p1b"
const ARENA_P1C_ID: StringName = &"p1c"
const ARENA_P1D_ID: StringName = &"p1d"
const ARENA_P1E_ID: StringName = &"p1e"
const ARENA_P2_ID: StringName = &"p2"
const ARENA_P3_ID: StringName = &"p3"
const P1A_TAB_INDEX := 0
const P1_TAB_INDEX := P1A_TAB_INDEX
const P1B_TAB_INDEX := 1
const P1C_TAB_INDEX := 2
const P1D_TAB_INDEX := 3
const P1E_TAB_INDEX := 4
const P2_TAB_INDEX := 5
const P3_TAB_INDEX := 6
const OPEN_FADE_DURATION := 0.14
const OPEN_PANEL_DURATION := 0.18

@onready var root_control: Control = $Root
@onready var dim: ColorRect = $Root/Dim
@onready var panel: PanelContainer = $Root/Center/Panel
@onready var tabs: TabContainer = $Root/Center/Panel/PanelMargin/Layout/Tabs
@onready var p1a_enter_button: Button = (
	$Root/Center/Panel/PanelMargin/Layout/Tabs/P1A/PageMargin/Content/EnterButton
)
@onready var p1b_enter_button: Button = (
	$Root/Center/Panel/PanelMargin/Layout/Tabs/P1B/PageMargin/Content/EnterButton
)
@onready var p1c_enter_button: Button = (
	$Root/Center/Panel/PanelMargin/Layout/Tabs/P1C/PageMargin/Content/EnterButton
)
@onready var p1d_enter_button: Button = (
	$Root/Center/Panel/PanelMargin/Layout/Tabs/P1D/PageMargin/Content/EnterButton
)
@onready var p1e_enter_button: Button = (
	$Root/Center/Panel/PanelMargin/Layout/Tabs/P1E/PageMargin/Content/EnterButton
)
@onready var p2_enter_button: Button = (
	$Root/Center/Panel/PanelMargin/Layout/Tabs/P2/PageMargin/Content/EnterButton
)
@onready var p3_enter_button: Button = (
	$Root/Center/Panel/PanelMargin/Layout/Tabs/P3/PageMargin/Content/EnterButton
)

var open_tween: Tween


func _ready() -> void:
	tabs.set_tab_hidden(
		P1E_TAB_INDEX,
		not GameModeCatalog.is_development_selectable(
			GameModeCatalog.MODE_TEST_ARENA_P1E
		)
	)
	visible = false
	root_control.hide()
	set_process_unhandled_input(false)


func open(initial_arena_id: StringName = ARENA_P1A_ID) -> void:
	_select_tab(initial_arena_id)
	if is_open():
		call_deferred("_focus_current_action")
		return

	visible = true
	root_control.show()
	set_process_unhandled_input(true)
	_prepare_open_animation()
	call_deferred("_play_open_animation")


func close() -> void:
	_hide_overlay(true)


func is_open() -> bool:
	return visible and root_control.visible


func _unhandled_input(event: InputEvent) -> void:
	if not is_open():
		return
	if event.is_action_pressed(&"quit"):
		close()
		get_viewport().set_input_as_handled()


func _on_p1a_pressed() -> void:
	_choose_arena(ARENA_P1A_ID)


func _on_p1b_pressed() -> void:
	_choose_arena(ARENA_P1B_ID)


func _on_p1c_pressed() -> void:
	_choose_arena(ARENA_P1C_ID)


func _on_p1d_pressed() -> void:
	_choose_arena(ARENA_P1D_ID)


func _on_p1e_pressed() -> void:
	_choose_arena(ARENA_P1E_ID)


func _on_p2_pressed() -> void:
	_choose_arena(ARENA_P2_ID)


func _on_p3_pressed() -> void:
	_choose_arena(ARENA_P3_ID)


func _on_back_pressed() -> void:
	close()


func _on_tab_changed(_tab_index: int) -> void:
	call_deferred("_focus_current_action")


func _choose_arena(arena_id: StringName) -> void:
	if not is_open():
		return
	if (
		arena_id == ARENA_P1E_ID
		and not GameModeCatalog.is_development_selectable(
			GameModeCatalog.MODE_TEST_ARENA_P1E
		)
	):
		return
	_hide_overlay(false)
	arena_selected.emit(arena_id)


func _hide_overlay(emit_closed_signal: bool) -> void:
	if not is_open():
		return
	if open_tween != null:
		open_tween.kill()
		open_tween = null
	root_control.hide()
	visible = false
	set_process_unhandled_input(false)
	if emit_closed_signal:
		selection_closed.emit()


func _select_tab(arena_id: StringName) -> void:
	match arena_id:
		ARENA_P1B_ID:
			tabs.current_tab = P1B_TAB_INDEX
		ARENA_P1C_ID:
			tabs.current_tab = P1C_TAB_INDEX
		ARENA_P1D_ID:
			tabs.current_tab = P1D_TAB_INDEX
		ARENA_P1E_ID:
			tabs.current_tab = (
				P1E_TAB_INDEX
				if GameModeCatalog.is_development_selectable(
					GameModeCatalog.MODE_TEST_ARENA_P1E
				)
				else P1A_TAB_INDEX
			)
		ARENA_P2_ID:
			tabs.current_tab = P2_TAB_INDEX
		ARENA_P3_ID:
			tabs.current_tab = P3_TAB_INDEX
		_:
			tabs.current_tab = P1A_TAB_INDEX


func _focus_current_action() -> void:
	if not is_open():
		return
	match tabs.current_tab:
		P1B_TAB_INDEX:
			p1b_enter_button.grab_focus()
		P1C_TAB_INDEX:
			p1c_enter_button.grab_focus()
		P1D_TAB_INDEX:
			p1d_enter_button.grab_focus()
		P1E_TAB_INDEX:
			p1e_enter_button.grab_focus()
		P2_TAB_INDEX:
			p2_enter_button.grab_focus()
		P3_TAB_INDEX:
			p3_enter_button.grab_focus()
		_:
			p1a_enter_button.grab_focus()


func _prepare_open_animation() -> void:
	if open_tween != null:
		open_tween.kill()
		open_tween = null
	dim.modulate = Color(1.0, 1.0, 1.0, 0.0)
	panel.modulate = Color(1.0, 1.0, 1.0, 0.0)
	panel.scale = Vector2(0.975, 0.975)


func _play_open_animation() -> void:
	if not is_open():
		return
	panel.pivot_offset = panel.size * 0.5
	open_tween = create_tween()
	open_tween.set_parallel(true)
	open_tween.tween_property(dim, "modulate", Color.WHITE, OPEN_FADE_DURATION).set_trans(
		Tween.TRANS_SINE
	).set_ease(Tween.EASE_OUT)
	open_tween.tween_property(panel, "modulate", Color.WHITE, OPEN_PANEL_DURATION).set_trans(
		Tween.TRANS_QUAD
	).set_ease(Tween.EASE_OUT)
	open_tween.tween_property(panel, "scale", Vector2.ONE, OPEN_PANEL_DURATION).set_trans(
		Tween.TRANS_QUAD
	).set_ease(Tween.EASE_OUT)
	open_tween.finished.connect(func() -> void:
		open_tween = null
		_focus_current_action()
	)
