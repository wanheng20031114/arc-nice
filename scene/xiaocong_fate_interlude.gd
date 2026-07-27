extends Node2D
class_name XiaocongFateInterlude

signal interaction_requested
signal fate_choice_submitted(option_index: int, permanent_buff_id: int)
signal collectible_choice_submitted(choice_index: int)

const PLAYER_OFFSETS: Array[Vector2] = [
	Vector2(-46, 42),
	Vector2(46, 42),
	Vector2(-82, 66),
	Vector2(82, 66),
	Vector2(-118, 86),
	Vector2(118, 86),
	Vector2(-154, 104),
	Vector2(154, 104),
]

@onready var interaction_area: Area2D = $InteractionArea
@onready var interaction_shape: CollisionShape2D = $InteractionArea/CollisionShape2D
@onready var dialogue_bubble: MerchantDialogueBubble = $XiaocongDialogueBubble
@onready var prompt_label: Label = $InteractionPrompt
@onready var choice_overlay: XiaocongFateChoiceOverlay = $XiaocongFateChoiceOverlay

var is_active := false
var completed_day := 1
var local_player: Player = null
var local_peer_id := 0
var nearby_local_player := false
var local_interaction_sent := false
var character_ids_by_peer: Dictionary = {}
var current_stage := &"wait_interactions"


func _ready() -> void:
	interaction_area.body_entered.connect(_on_body_entered)
	interaction_area.body_exited.connect(_on_body_exited)
	choice_overlay.choice_submitted.connect(fate_choice_submitted.emit)
	choice_overlay.collectible_submitted.connect(collectible_choice_submitted.emit)
	set_active(false)


func configure_local_player(
	player_node: Player,
	peer_id: int,
	peer_character_ids: Dictionary
) -> void:
	local_player = player_node
	local_peer_id = peer_id
	character_ids_by_peer = peer_character_ids.duplicate()


func set_active(active: bool, day_number: int = 1) -> void:
	is_active = active
	completed_day = maxi(day_number, 1)
	visible = active
	process_mode = Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED
	interaction_shape.set_deferred("disabled", not active)
	interaction_area.set_deferred("monitoring", active)
	nearby_local_player = false
	local_interaction_sent = false
	current_stage = &"wait_interactions"
	prompt_label.visible = false
	dialogue_bubble.hide_bubble()
	if not active:
		choice_overlay.hide_overlay()


func apply_fate_state(state: Dictionary) -> void:
	var active := bool(state.get("active", false))
	if active != is_active:
		set_active(active, int(state.get("completed_day", completed_day)))
	if not active:
		return
	completed_day = maxi(int(state.get("completed_day", completed_day)), 1)
	var interacted := state.get("interacted_peer_ids", []) as Array
	local_interaction_sent = interacted.has(local_peer_id)
	current_stage = StringName(state.get("stage", &"wait_interactions"))
	choice_overlay.apply_state(state, local_peer_id, character_ids_by_peer)
	_refresh_prompt()


func get_player_spawn_position(slot_index: int) -> Vector2:
	var safe_index := posmod(slot_index, PLAYER_OFFSETS.size())
	return global_position + PLAYER_OFFSETS[safe_index]


func _unhandled_input(event: InputEvent) -> void:
	if not is_active or not nearby_local_player:
		return
	if not event.is_action_pressed(&"interact"):
		return
	get_viewport().set_input_as_handled()
	if dialogue_bubble.is_revealing:
		dialogue_bubble.finish_line()
		return
	dialogue_bubble.say(
		"你已经通过了第%d天，该决定接下来的命运了" % completed_day
	)
	if not local_interaction_sent:
		local_interaction_sent = true
		interaction_requested.emit()
	_refresh_prompt()


func _on_body_entered(body: Node2D) -> void:
	if not is_active or body != local_player:
		return
	nearby_local_player = true
	_refresh_prompt()


func _on_body_exited(body: Node2D) -> void:
	if body != local_player:
		return
	nearby_local_player = false
	prompt_label.visible = false
	dialogue_bubble.hide_bubble()


func _refresh_prompt() -> void:
	prompt_label.visible = is_active and nearby_local_player
	if current_stage == &"voting":
		prompt_label.text = "命运选择已经开启"
	elif current_stage == &"resolving":
		prompt_label.text = "小葱正在改写命运"
	elif current_stage == &"resolved":
		prompt_label.text = "命运已经决定"
	elif current_stage == &"collectible_reward":
		prompt_label.text = "请完成你的收藏品选择"
	elif local_interaction_sent:
		prompt_label.text = "已与小葱交互 · 等待所有玩家"
	else:
		prompt_label.text = "F  与小葱交互"
