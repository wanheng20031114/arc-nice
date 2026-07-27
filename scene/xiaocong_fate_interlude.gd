extends Node2D
class_name XiaocongFateInterlude

signal interaction_requested
signal fate_choice_submitted(option_id: StringName, permanent_buff_id: StringName)
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
var current_stage := TowerDefenseFateManager.STAGE_WAIT_INTERACTIONS
var eligible_player_count := 0
var interacted_player_count := 0
var timeout_seconds_left := 0
var timeout_recovery_available := false
var local_is_host := false


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
	current_stage = TowerDefenseFateManager.STAGE_WAIT_INTERACTIONS
	eligible_player_count = 0
	interacted_player_count = 0
	timeout_seconds_left = 0
	timeout_recovery_available = false
	local_is_host = false
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
	var interacted := _to_int_array(state.get("interacted_peer_ids", []))
	local_interaction_sent = interacted.has(local_peer_id)
	current_stage = StringName(
		state.get("stage", TowerDefenseFateManager.STAGE_WAIT_INTERACTIONS)
	)
	eligible_player_count = _to_int_array(
		state.get("eligible_peer_ids", [])
	).size()
	interacted_player_count = interacted.size()
	timeout_seconds_left = ceili(float(state.get("stage_time_remaining", 0.0)))
	timeout_recovery_available = bool(
		state.get("timeout_recovery_available", false)
	)
	local_is_host = int(state.get("host_peer_id", -1)) == local_peer_id
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
	if (
		current_stage == TowerDefenseFateManager.STAGE_WAIT_INTERACTIONS
		and not local_interaction_sent
	):
		local_interaction_sent = true
		interaction_requested.emit()
	elif timeout_recovery_available and local_is_host:
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
	if current_stage == TowerDefenseFateManager.STAGE_VOTING:
		prompt_label.text = (
			"等待超时 · F 由房主继续结算"
			if timeout_recovery_available and local_is_host
			else "命运选择已经开启 · 剩余 %d 秒" % timeout_seconds_left
		)
	elif current_stage == TowerDefenseFateManager.STAGE_RESOLVING:
		prompt_label.text = "小葱正在改写命运"
	elif current_stage == TowerDefenseFateManager.STAGE_RESOLVED:
		prompt_label.text = "命运已经决定"
	elif current_stage == TowerDefenseFateManager.STAGE_COLLECTIBLE_REWARD:
		prompt_label.text = "请完成你的收藏品选择"
	elif timeout_recovery_available and local_is_host:
		prompt_label.text = "等待超时 · F 由房主继续流程"
	elif local_interaction_sent:
		prompt_label.text = "已交互 %d/%d · 剩余 %d 秒" % [
			interacted_player_count,
			eligible_player_count,
			timeout_seconds_left,
		]
	else:
		prompt_label.text = "F  与小葱交互"


func _to_int_array(value: Variant) -> Array[int]:
	var result: Array[int] = []
	if value is Array or value is PackedInt32Array:
		for entry in value:
			result.append(int(entry))
	return result
