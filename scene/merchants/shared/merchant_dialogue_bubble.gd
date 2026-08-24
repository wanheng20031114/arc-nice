extends Node2D
class_name MerchantDialogueBubble

const LETTER_TIME := DialogueTypewriterController.LETTER_TIME
const COMMA_TIME := DialogueTypewriterController.COMMA_TIME
const PUNCTUATION_TIME := DialogueTypewriterController.PUNCTUATION_TIME
const NO_BREAK_MARK := DialogueTypewriterController.NO_BREAK_MARK
# World and ambient effects occupy layers 0-1; player-facing UI starts at 5.
const CANVAS_LAYER := 4

@export var dialogue_layer_index := CANVAS_LAYER

@onready var dialogue_layer: CanvasLayer = $DialogueLayer
@onready var canvas_anchor: Node2D = $DialogueLayer/Anchor
@onready var text_label: RichTextLabel = (
	$DialogueLayer/Anchor/BubblePanel/Margin/Content/Text
)
@onready var keyboard_prompt: Label = (
	$DialogueLayer/Anchor/BubblePanel/Margin/Content/PromptRow/KeyboardPrompt
)
@onready var gamepad_prompt: Label = (
	$DialogueLayer/Anchor/BubblePanel/Margin/Content/PromptRow/YButton/YLabel
)
@onready var blip_audio: AudioStreamPlayer = $BlipAudio
@onready var typewriter: DialogueTypewriterController = $Typewriter

var is_revealing: bool:
	get:
		return typewriter != null and typewriter.is_revealing()


func _ready() -> void:
	dialogue_layer.layer = dialogue_layer_index
	typewriter.configure(text_label, blip_audio)
	var settings := get_node_or_null("/root/UserSettings")
	if settings != null:
		var binding_callback := Callable(self, "_on_action_bindings_changed")
		if not settings.is_connected(&"action_bindings_changed", binding_callback):
			settings.connect(&"action_bindings_changed", binding_callback)
		_refresh_interaction_binding_presentation()
	visibility_changed.connect(_on_visibility_changed)
	dialogue_layer.visible = is_visible_in_tree()
	_sync_canvas_anchor()
	set_process(is_visible_in_tree())


func _process(delta: float) -> void:
	var _unused_delta := delta
	_sync_canvas_anchor()


func say(text: String) -> void:
	visible = true
	typewriter.say(text)
	set_process(true)


func finish_line() -> void:
	typewriter.finish_line()


func hide_bubble() -> void:
	finish_line()
	visible = false


func _on_visibility_changed() -> void:
	var should_show := is_visible_in_tree()
	dialogue_layer.visible = should_show
	set_process(should_show)
	if should_show:
		_sync_canvas_anchor()


func _sync_canvas_anchor() -> void:
	var viewport_transform := get_global_transform_with_canvas()
	viewport_transform.origin = viewport_transform.origin.round()
	canvas_anchor.transform = viewport_transform


func _on_action_bindings_changed(action: StringName) -> void:
	if action == &"interact":
		_refresh_interaction_binding_presentation()


func _refresh_interaction_binding_presentation() -> void:
	var settings := get_node_or_null("/root/UserSettings")
	if settings == null:
		return
	var keyboard := str(
		settings.call(
			"get_primary_keyboard_binding_text",
			"interact",
			"—",
			true
		)
	)
	var gamepad := str(
		settings.call(
			"get_primary_gamepad_binding_text",
			"interact",
			"—",
			true
		)
	)
	keyboard_prompt.text = "按下 %s /" % keyboard
	gamepad_prompt.text = gamepad
