extends PanelContainer
class_name XiaocongFateChoiceCard

const VOTE_PORTRAIT_SCENE := preload("res://scene/ui/shared/vote_portrait.tscn")

signal selected(option_id: StringName)

@export var background_texture: Texture2D

@onready var button: Button = $Button
@onready var background: TextureRect = $Background
@onready var number_label: Label = $Content/Margin/Rows/Header/Number
@onready var title_label: Label = $Content/Margin/Rows/Header/Title
@onready var icon_rect: TextureRect = $Content/Margin/Rows/Header/Icon
@onready var description_label: Label = $Content/Margin/Rows/Description
@onready var vote_row: HBoxContainer = $Content/Margin/Rows/VoteRow

var option_id: StringName = &""
var display_index := 0
var entrance_tween: Tween = null
var resolution_tween: Tween = null
var resolved_winner := false


func _ready() -> void:
	button.pressed.connect(_on_button_pressed)
	resized.connect(_sync_pivot_offset)
	background.texture = background_texture
	_sync_pivot_offset()


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
	if not resolved_winner:
		self_modulate = (
			Color(0.62, 0.66, 0.63, 0.78)
			if is_disabled
			else Color.WHITE
		)


func set_selected(is_selected: bool) -> void:
	button.button_pressed = is_selected


func set_interaction_enabled(enabled: bool) -> void:
	button.mouse_filter = (
		Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE
	)
	button.focus_mode = Control.FOCUS_ALL if enabled else Control.FOCUS_NONE
	if not enabled and button.has_focus():
		button.release_focus()


func set_resolution_state(is_winner: bool, resolution_active: bool) -> void:
	if resolution_tween != null:
		resolution_tween.kill()
		resolution_tween = null
	resolved_winner = resolution_active and is_winner
	if not resolution_active:
		self_modulate = (
			Color.WHITE
			if not button.disabled
			else Color(0.62, 0.66, 0.63, 0.78)
		)
		scale = Vector2.ONE
		return
	if not is_winner:
		self_modulate = Color(0.38, 0.42, 0.4, 0.54)
		scale = Vector2.ONE
		return
	self_modulate = Color.WHITE
	resolution_tween = create_tween()
	resolution_tween.tween_property(
		self,
		"scale",
		Vector2(1.025, 1.025),
		0.14
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	resolution_tween.tween_property(
		self,
		"scale",
		Vector2.ONE,
		0.22
	).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func play_entrance(delay_seconds: float) -> void:
	# Containers assign their final child positions on the frame after the
	# overlay becomes visible, so the slide starts after that layout pass.
	await get_tree().process_frame
	if not is_inside_tree() or not is_visible_in_tree():
		return
	if entrance_tween != null:
		entrance_tween.kill()
	modulate = Color(1, 1, 1, 0)
	var target_position := position
	position = target_position + Vector2(44, 0)
	entrance_tween = create_tween().set_parallel(true)
	entrance_tween.tween_property(
		self,
		"position",
		target_position,
		0.34
	).set_delay(delay_seconds).set_trans(Tween.TRANS_BACK).set_ease(
		Tween.EASE_OUT
	)
	entrance_tween.tween_property(
		self,
		"modulate",
		Color.WHITE,
		0.22
	).set_delay(delay_seconds)
	entrance_tween.finished.connect(func() -> void: entrance_tween = null)


func set_voters(peer_ids: Array[int], character_ids_by_peer: Dictionary) -> void:
	for child in vote_row.get_children():
		var portrait := child as Control
		if portrait == null or bool(portrait.get_meta(&"exiting", false)):
			continue
		var peer_id := int(portrait.get_meta(&"peer_id", -1))
		if not peer_ids.has(peer_id):
			_animate_voter_out(portrait)
	for peer_id in peer_ids:
		if _has_voter_portrait(peer_id):
			continue
		var character_id := StringName(
			character_ids_by_peer.get(
				peer_id,
				PlayerCharacterRegistry.get_default_character_id()
			)
		)
		var character_config := PlayerCharacterRegistry.get_config(character_id)
		if (
			character_config == null
			or character_config.portrait_texture.is_empty()
		):
			continue
		var portrait := VOTE_PORTRAIT_SCENE.instantiate() as PanelContainer
		var texture_rect := portrait.get_node(
			"PortraitLayer/TextureRect"
		) as TextureRect
		var portrait_texture := load(
			character_config.portrait_texture
		) as Texture2D
		if portrait_texture == null:
			portrait.queue_free()
			continue
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
		portrait.modulate = Color(1, 1, 1, 0)
		portrait.pivot_offset = portrait.custom_minimum_size * 0.5
		portrait.scale = Vector2(0.72, 0.72)
		var tween := portrait.create_tween().set_parallel(true)
		tween.tween_property(portrait, "modulate", Color.WHITE, 0.18)
		tween.tween_property(
			portrait,
			"scale",
			Vector2.ONE,
			0.28
		).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _on_button_pressed() -> void:
	if not option_id.is_empty():
		selected.emit(option_id)


func _has_voter_portrait(peer_id: int) -> bool:
	for child in vote_row.get_children():
		if (
			int(child.get_meta(&"peer_id", -1)) == peer_id
			and not child.is_queued_for_deletion()
		):
			return true
	return false


func _animate_voter_out(portrait: Control) -> void:
	if bool(portrait.get_meta(&"exiting", false)):
		return
	portrait.set_meta(&"exiting", true)
	portrait.set_meta(&"peer_id", -1)
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tween := portrait.create_tween().set_parallel(true)
	tween.tween_property(portrait, "modulate:a", 0.0, 0.12)
	tween.tween_property(
		portrait,
		"scale",
		Vector2(0.72, 0.72),
		0.18
	).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(portrait.queue_free)


func _sync_pivot_offset() -> void:
	pivot_offset = size * 0.5
