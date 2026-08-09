extends PanelContainer
class_name RogueSupplyChoiceCard

signal selected(option_id: StringName)

const MAX_VOTER_PORTRAITS := 8
const DISABLED_MODULATE := Color(0.82, 0.8, 0.74, 1.0)
const LOSER_MODULATE := Color(0.66, 0.64, 0.6, 1.0)

@export var background_texture: Texture2D

@onready var background: TextureRect = $Background
@onready var button: Button = $Button
@onready var number_label: Label = $Content/Margin/Rows/Header/Number
@onready var title_label: Label = $Content/Margin/Rows/Header/Title
@onready var description_label: Label = $Content/Margin/Rows/Description
@onready var disabled_reason_label: Label = (
	$Content/Margin/Rows/Footer/DisabledReason
)
@onready var light_stone_cost: HBoxContainer = (
	$Content/Margin/Rows/Footer/LightStoneCost
)
@onready var light_stone_amount: Label = (
	$Content/Margin/Rows/Footer/LightStoneCost/Amount
)
@onready var voter_portraits: Array[PanelContainer] = [
	$Content/Margin/Rows/Footer/VoteRow/Voter0,
	$Content/Margin/Rows/Footer/VoteRow/Voter1,
	$Content/Margin/Rows/Footer/VoteRow/Voter2,
	$Content/Margin/Rows/Footer/VoteRow/Voter3,
	$Content/Margin/Rows/Footer/VoteRow/Voter4,
	$Content/Margin/Rows/Footer/VoteRow/Voter5,
	$Content/Margin/Rows/Footer/VoteRow/Voter6,
	$Content/Margin/Rows/Footer/VoteRow/Voter7,
]

var option_id: StringName = &""
var display_index := 0
var entrance_tween: Tween = null
var resolution_tween: Tween = null
var resolved_winner := false
var interaction_enabled := false


func _ready() -> void:
	button.pressed.connect(_on_button_pressed)
	resized.connect(_sync_pivot_offset)
	background.texture = background_texture
	for portrait in voter_portraits:
		portrait.visible = false
	_sync_pivot_offset()


func configure(
	option: Dictionary,
	new_display_index: int,
	shared_light_stone: int,
	local_can_vote: bool
) -> void:
	option_id = StringName(option.get("option_id", ""))
	display_index = maxi(new_display_index, 0)
	number_label.text = "%02d" % (display_index + 1)
	title_label.text = str(option.get("display_name", "未知物资"))
	description_label.text = str(option.get("description", ""))

	var cost := maxi(int(option.get("light_stone_cost", 0)), 0)
	var option_available := bool(option.get("available", true))
	var has_enough_light_stone := shared_light_stone >= cost
	var disabled := (
		not local_can_vote
		or not option_available
		or not has_enough_light_stone
		or option_id.is_empty()
	)
	button.disabled = disabled
	light_stone_cost.visible = cost > 0
	if cost > 0:
		light_stone_amount.text = "%d/%d" % [
			mini(maxi(shared_light_stone, 0), cost),
			cost,
		]
	var disabled_reason := str(option.get("disabled_reason", ""))
	if disabled_reason.is_empty() and cost > 0 and not has_enough_light_stone:
		disabled_reason = "光石不足"
	disabled_reason_label.text = disabled_reason
	disabled_reason_label.visible = disabled and not disabled_reason.is_empty()
	_refresh_interaction()
	if not resolved_winner:
		self_modulate = DISABLED_MODULATE if disabled else Color.WHITE


func set_selected(is_selected: bool) -> void:
	button.button_pressed = is_selected


func set_interaction_enabled(enabled: bool) -> void:
	interaction_enabled = enabled
	_refresh_interaction()


func set_resolution_state(is_winner: bool, resolution_active: bool) -> void:
	if resolution_tween != null:
		resolution_tween.kill()
		resolution_tween = null
	resolved_winner = resolution_active and is_winner
	if not resolution_active:
		self_modulate = DISABLED_MODULATE if button.disabled else Color.WHITE
		scale = Vector2.ONE
		return
	if not is_winner:
		self_modulate = LOSER_MODULATE
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


func set_voters(
	peer_ids: Array[int],
	character_ids_by_peer: Dictionary,
	player_names_by_peer: Dictionary
) -> void:
	var ordered_peer_ids: Array[int] = peer_ids.duplicate()
	ordered_peer_ids.sort()
	for portrait_index in range(MAX_VOTER_PORTRAITS):
		var portrait := voter_portraits[portrait_index]
		if portrait_index >= ordered_peer_ids.size():
			portrait.visible = false
			portrait.set_meta(&"peer_id", -1)
			continue
		var peer_id: int = ordered_peer_ids[portrait_index]
		var character_id := StringName(
			character_ids_by_peer.get(
				peer_id,
				PlayerCharacterRegistry.get_default_character_id()
			)
		)
		var character_config := PlayerCharacterRegistry.get_config(character_id)
		var texture_rect := portrait.get_node(
			"PortraitLayer/TextureRect"
		) as TextureRect
		if (
			character_config == null
			or character_config.portrait_texture.is_empty()
		):
			portrait.visible = false
			continue
		var portrait_texture := load(
			character_config.portrait_texture
		) as Texture2D
		if portrait_texture == null:
			portrait.visible = false
			continue
		var is_new_voter: bool = (
			not portrait.visible
			or int(portrait.get_meta(&"peer_id", -1)) != peer_id
		)
		portrait.set_meta(&"peer_id", peer_id)
		portrait.tooltip_text = str(
			player_names_by_peer.get(peer_id, character_config.display_name)
		)
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
		portrait.visible = true
		if is_new_voter:
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


func _refresh_interaction() -> void:
	var accepts_input := interaction_enabled and not button.disabled
	button.mouse_filter = (
		Control.MOUSE_FILTER_STOP
		if accepts_input
		else Control.MOUSE_FILTER_IGNORE
	)
	button.focus_mode = (
		Control.FOCUS_ALL if accepts_input else Control.FOCUS_NONE
	)
	if not accepts_input and button.has_focus():
		button.release_focus()


func _on_button_pressed() -> void:
	if not option_id.is_empty() and not button.disabled:
		selected.emit(option_id)


func _sync_pivot_offset() -> void:
	pivot_offset = size * 0.5
