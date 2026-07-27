extends PanelContainer
class_name XiaocongFateChoiceCard

const VOTE_PORTRAIT_SCENE := preload("res://scene/xiaocong_vote_portrait.tscn")

signal selected(option_id: StringName)

@onready var button: Button = $Button
@onready var number_label: Label = $Content/Margin/Rows/Header/Number
@onready var title_label: Label = $Content/Margin/Rows/Header/Title
@onready var icon_rect: TextureRect = $Content/Margin/Rows/Header/Icon
@onready var description_label: Label = $Content/Margin/Rows/Description
@onready var vote_row: HBoxContainer = $Content/Margin/Rows/VoteRow

var option_id: StringName = &""
var display_index := 0


func _ready() -> void:
	button.pressed.connect(_on_button_pressed)


func configure(
	config: TowerDefenseFateOptionConfig,
	new_display_index: int,
	is_disabled: bool = false
) -> void:
	if config == null:
		return
	option_id = config.option_id
	display_index = maxi(new_display_index, 0)
	number_label.text = "%02d" % (display_index + 1)
	title_label.text = config.display_name
	description_label.text = config.description
	icon_rect.texture = config.icon
	icon_rect.visible = config.icon != null
	button.disabled = is_disabled
	self_modulate = Color(0.55, 0.59, 0.56, 0.72) if is_disabled else Color.WHITE


func set_selected(is_selected: bool) -> void:
	button.button_pressed = is_selected


func set_voters(peer_ids: Array[int], character_ids_by_peer: Dictionary) -> void:
	for child in vote_row.get_children():
		child.queue_free()
	for peer_id in peer_ids:
		var character_id := StringName(
			character_ids_by_peer.get(
				peer_id,
				PlayerCharacterRegistry.get_default_character_id()
			)
		)
		var config := PlayerCharacterRegistry.get_config(character_id)
		if config == null or config.portrait_texture.is_empty():
			continue
		var portrait := VOTE_PORTRAIT_SCENE.instantiate() as PanelContainer
		var texture_rect := portrait.get_node("TextureRect") as TextureRect
		texture_rect.texture = load(config.portrait_texture) as Texture2D
		portrait.tooltip_text = config.display_name
		vote_row.add_child(portrait)


func _on_button_pressed() -> void:
	if not option_id.is_empty():
		selected.emit(option_id)
