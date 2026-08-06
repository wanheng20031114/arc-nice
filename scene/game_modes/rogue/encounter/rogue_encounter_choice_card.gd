extends NinePatchRect
class_name RogueEncounterChoiceCard

const VOTE_PORTRAIT_SCENE := preload("res://scene/xiaocong_vote_portrait.tscn")

signal selected(option_id: StringName)

@onready var button: Button = $Button
@onready var number_label: Label = $Content/Margin/Rows/Header/Number
@onready var title_label: Label = $Content/Margin/Rows/Header/Title
@onready var icon_rect: TextureRect = $Content/Margin/Rows/Header/Icon
@onready var description_label: Label = $Content/Margin/Rows/Description
@onready var vote_row: HBoxContainer = $Content/Margin/Rows/VoteRow

var option_id: StringName = &""


func _ready() -> void:
	button.pressed.connect(_on_button_pressed)


func configure(
	new_option_id: StringName,
	display_index: int,
	title: String,
	description: String,
	icon: Texture2D,
	is_disabled: bool
) -> void:
	visible = true
	option_id = new_option_id
	number_label.text = "%02d" % (display_index + 1)
	title_label.text = title
	description_label.text = description
	description_label.visible = not description.is_empty()
	icon_rect.texture = icon
	icon_rect.visible = icon != null
	button.disabled = is_disabled
	self_modulate = (
		Color(0.62, 0.59, 0.52, 0.7)
		if is_disabled
		else Color.WHITE
	)


func reset_card() -> void:
	option_id = &""
	number_label.text = ""
	title_label.text = ""
	description_label.text = ""
	icon_rect.texture = null
	icon_rect.visible = false
	button.button_pressed = false
	button.disabled = true
	set_interaction_enabled(false)
	set_voters([], {})
	self_modulate = Color.WHITE
	visible = false


func set_selected(is_selected: bool) -> void:
	button.button_pressed = is_selected


func set_interaction_enabled(enabled: bool) -> void:
	button.mouse_filter = (
		Control.MOUSE_FILTER_STOP
		if enabled
		else Control.MOUSE_FILTER_IGNORE
	)
	button.focus_mode = Control.FOCUS_ALL if enabled else Control.FOCUS_NONE
	if not enabled and button.has_focus():
		button.release_focus()


func set_voters(
	peer_ids: Array[int],
	character_ids_by_peer: Dictionary
) -> void:
	for child in vote_row.get_children():
		var portrait := child as Control
		if portrait == null:
			continue
		var peer_id := int(portrait.get_meta(&"peer_id", -1))
		if not peer_ids.has(peer_id):
			portrait.queue_free()
	for peer_id in peer_ids:
		if _has_voter_portrait(peer_id):
			continue
		_add_voter_portrait(peer_id, character_ids_by_peer)


func _on_button_pressed() -> void:
	if not option_id.is_empty() and not button.disabled:
		selected.emit(option_id)


func _has_voter_portrait(peer_id: int) -> bool:
	for child in vote_row.get_children():
		if (
			int(child.get_meta(&"peer_id", -1)) == peer_id
			and not child.is_queued_for_deletion()
		):
			return true
	return false


func _add_voter_portrait(
	peer_id: int,
	character_ids_by_peer: Dictionary
) -> void:
	var character_id := StringName(
		character_ids_by_peer.get(
			peer_id,
			PlayerCharacterRegistry.get_default_character_id()
		)
	)
	var character_config := PlayerCharacterRegistry.get_config(character_id)
	if character_config == null or character_config.portrait_texture.is_empty():
		return
	var portrait := VOTE_PORTRAIT_SCENE.instantiate() as PanelContainer
	var texture_rect := portrait.get_node(
		"PortraitLayer/TextureRect"
	) as TextureRect
	var portrait_texture := load(
		character_config.portrait_texture
	) as Texture2D
	if portrait_texture == null:
		portrait.queue_free()
		return
	texture_rect.texture = portrait_texture
	var portrait_size := portrait.custom_minimum_size
	var portrait_scale := minf(
		portrait_size.x / portrait_texture.get_width(),
		portrait_size.y / portrait_texture.get_height()
	)
	texture_rect.position = Vector2(
		roundf(character_config.portrait_offset.x * portrait_scale),
		roundf(character_config.portrait_offset.y * portrait_scale)
	)
	portrait.tooltip_text = character_config.display_name
	portrait.set_meta(&"peer_id", peer_id)
	vote_row.add_child(portrait)
