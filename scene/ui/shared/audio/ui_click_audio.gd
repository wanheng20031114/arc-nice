extends Node

const SKIP_CLICK_AUDIO_META := &"skip_ui_click_audio"

@onready var click_audio: AudioStreamPlayer = $ClickAudio

var _connected_button_ids: Dictionary = {}
var _random := RandomNumberGenerator.new()


func _ready() -> void:
	_random.randomize()
	get_tree().node_added.connect(_on_node_added)
	_connect_buttons_in_tree(get_tree().root)


func _on_node_added(node: Node) -> void:
	_try_connect_button(node)


func _connect_buttons_in_tree(node: Node) -> void:
	_try_connect_button(node)
	for child in node.get_children():
		_connect_buttons_in_tree(child)


func _try_connect_button(node: Node) -> void:
	var button := node as BaseButton
	if button == null:
		return
	var button_id := button.get_instance_id()
	if _connected_button_ids.has(button_id):
		return
	_connected_button_ids[button_id] = true
	button.pressed.connect(_on_button_pressed.bind(button))
	button.tree_exiting.connect(_on_button_tree_exiting.bind(button_id), CONNECT_ONE_SHOT)


func _on_button_pressed(button: BaseButton) -> void:
	if button == null or button.disabled:
		return
	if bool(button.get_meta(SKIP_CLICK_AUDIO_META, false)):
		return
	click_audio.pitch_scale = _random.randf_range(0.992, 1.008)
	click_audio.play()


func _on_button_tree_exiting(button_id: int) -> void:
	_connected_button_ids.erase(button_id)
