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
const XIAOCONG_WORLD_SCALE := Vector2.ONE
const SCENE_COVER_DURATION_SECONDS := 0.32
const ROOM_REVEAL_DURATION_SECONDS := 0.38
const OUTCOME_BLACKOUT_SECONDS := 0.14
const OUTCOME_TEXT_FADE_IN_SECONDS := 0.3
const OUTCOME_TEXT_HOLD_SECONDS := 0.9
const OUTCOME_TEXT_FADE_OUT_SECONDS := 0.24
const OUTCOME_ROOM_RESTORE_SECONDS := 0.14
const DEFAULT_OUTCOME_TEXT := "队伍做出了一个选择..."
const FATE_STONE_OUTCOME_TEXT := "世界发生了改变"

@onready var room_root: Node2D = $RoomRoot
@onready var xiaocong_sprite: AnimatedSprite2D = $RoomRoot/Xiaocong
@onready var body_shape: CollisionShape2D = (
	$RoomRoot/StaticBody2D/CollisionShape2D
)
@onready var room_boundary_shapes: Array[CollisionShape2D] = [
	$RoomRoot/RoomBounds/TopWall,
	$RoomRoot/RoomBounds/BottomWall,
	$RoomRoot/RoomBounds/LeftWall,
	$RoomRoot/RoomBounds/RightWall,
]
@onready var interaction_area: Area2D = $RoomRoot/InteractionArea
@onready var interaction_shape: CollisionShape2D = (
	$RoomRoot/InteractionArea/CollisionShape2D
)
@onready var dialogue_bubble: MerchantDialogueBubble = (
	$InteractionUILayer/Anchor/XiaocongDialogueBubble
)
@onready var interaction_ui_layer: CanvasLayer = $InteractionUILayer
@onready var interaction_ui_anchor: Node2D = $InteractionUILayer/Anchor
@onready var prompt_label: Label = (
	$InteractionUILayer/Anchor/InteractionPrompt
)
@onready var choice_overlay: XiaocongFateChoiceOverlay = (
	$XiaocongFateChoiceOverlay
)
@onready var outcome_layer: CanvasLayer = $OutcomeLayer
@onready var outcome_root: Control = $OutcomeLayer/Root
@onready var outcome_shade: ColorRect = $OutcomeLayer/Root/Shade
@onready var outcome_label: Label = $OutcomeLayer/Root/Message
@onready var scene_transition_layer: CanvasLayer = $SceneTransitionLayer
@onready var scene_transition_cover: ColorRect = $SceneTransitionLayer/Cover
@onready var transition_cover_audio: AudioStreamPlayer = $TransitionCoverAudio
@onready var transition_reveal_audio: AudioStreamPlayer = $TransitionRevealAudio

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
var last_winning_option_id: StringName = &""
var is_concluding := false
var scene_transition_progress := 0.0
var scene_transition_tween: Tween = null
var outcome_tween: Tween = null


func _ready() -> void:
	interaction_area.body_entered.connect(_on_body_entered)
	interaction_area.body_exited.connect(_on_body_exited)
	choice_overlay.choice_submitted.connect(fate_choice_submitted.emit)
	choice_overlay.collectible_submitted.connect(collectible_choice_submitted.emit)
	_set_scene_transition_progress(0.0)
	set_active(false)


func _process(_delta: float) -> void:
	if is_active:
		_update_interaction_ui_position()


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
	room_root.visible = active
	interaction_ui_layer.visible = active
	body_shape.set_deferred("disabled", not active)
	for boundary_shape in room_boundary_shapes:
		boundary_shape.set_deferred("disabled", not active)
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
	is_concluding = false
	prompt_label.visible = false
	dialogue_bubble.hide_bubble()
	xiaocong_sprite.position = Vector2.ZERO
	xiaocong_sprite.scale = XIAOCONG_WORLD_SCALE
	xiaocong_sprite.modulate = Color.WHITE
	_hide_outcome_immediately()
	if active:
		last_winning_option_id = &""
		xiaocong_sprite.play(&"idle")
		_update_interaction_ui_position()
	else:
		transition_cover_audio.stop()
		transition_reveal_audio.stop()
		choice_overlay.hide_overlay()


func apply_fate_state(state: Dictionary) -> void:
	var state_is_active := bool(state.get("active", false))
	last_winning_option_id = StringName(
		state.get("winning_option_id", last_winning_option_id)
	)
	if not state_is_active:
		if is_active:
			_prepare_conclusion()
		return
	if not is_active:
		set_active(true, int(state.get("completed_day", completed_day)))
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


func cover_scene_for_transfer() -> void:
	_stop_scene_transition_tween()
	scene_transition_layer.visible = true
	scene_transition_cover.mouse_filter = Control.MOUSE_FILTER_STOP
	if scene_transition_progress >= 0.999:
		_set_scene_transition_progress(1.0)
		return
	transition_cover_audio.play()
	var duration := maxf(
		SCENE_COVER_DURATION_SECONDS * (1.0 - scene_transition_progress),
		0.07
	)
	var tween := scene_transition_layer.create_tween()
	scene_transition_tween = tween
	tween.tween_method(
		_set_scene_transition_progress,
		scene_transition_progress,
		1.0,
		duration
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tween.finished
	if scene_transition_tween != tween:
		return
	scene_transition_tween = null
	_set_scene_transition_progress(1.0)


func play_room_reveal() -> void:
	_stop_scene_transition_tween()
	scene_transition_layer.visible = true
	scene_transition_cover.mouse_filter = Control.MOUSE_FILTER_STOP
	_set_scene_transition_progress(1.0)
	transition_reveal_audio.play()
	xiaocong_sprite.position = Vector2.ZERO
	xiaocong_sprite.scale = XIAOCONG_WORLD_SCALE
	xiaocong_sprite.modulate = Color(1, 1, 1, 0)
	var tween := scene_transition_layer.create_tween().set_parallel(true)
	scene_transition_tween = tween
	tween.tween_method(
		_set_scene_transition_progress,
		1.0,
		0.0,
		ROOM_REVEAL_DURATION_SECONDS
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(
		xiaocong_sprite,
		"modulate",
		Color.WHITE,
		0.2
	).set_delay(0.08)
	await tween.finished
	if scene_transition_tween != tween:
		return
	scene_transition_tween = null
	_finish_scene_reveal()


func reveal_world_after_transfer() -> void:
	_stop_scene_transition_tween()
	scene_transition_layer.visible = true
	scene_transition_cover.mouse_filter = Control.MOUSE_FILTER_STOP
	_set_scene_transition_progress(1.0)
	transition_reveal_audio.play()
	var tween := scene_transition_layer.create_tween()
	scene_transition_tween = tween
	tween.tween_method(
		_set_scene_transition_progress,
		1.0,
		0.0,
		ROOM_REVEAL_DURATION_SECONDS
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tween.finished
	if scene_transition_tween != tween:
		return
	scene_transition_tween = null
	_finish_scene_reveal()


func play_outcome_message(winning_option_id: StringName = &"") -> void:
	if not is_active:
		return
	_prepare_conclusion()
	await choice_overlay.play_return_to_room()
	if not is_inside_tree() or not is_active:
		return
	var resolved_option := (
		winning_option_id
		if not winning_option_id.is_empty()
		else last_winning_option_id
	)
	outcome_label.text = (
		FATE_STONE_OUTCOME_TEXT
		if resolved_option == TowerDefenseFateRegistry.OPTION_FATE_STONE
		else DEFAULT_OUTCOME_TEXT
	)
	outcome_root.modulate = Color.WHITE
	outcome_shade.modulate = Color(1, 1, 1, 0)
	outcome_label.modulate = Color(0.72, 0.78, 0.82, 0)
	outcome_layer.visible = true
	if outcome_tween != null:
		outcome_tween.kill()
	var tween := outcome_layer.create_tween()
	outcome_tween = tween
	tween.tween_property(
		outcome_shade,
		"modulate:a",
		1.0,
		OUTCOME_BLACKOUT_SECONDS
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(
		outcome_label,
		"modulate",
		Color.WHITE,
		OUTCOME_TEXT_FADE_IN_SECONDS
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_interval(OUTCOME_TEXT_HOLD_SECONDS)
	tween.tween_property(
		outcome_label,
		"modulate:a",
		0.0,
		OUTCOME_TEXT_FADE_OUT_SECONDS
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tween.tween_property(
		outcome_shade,
		"modulate:a",
		0.0,
		OUTCOME_ROOM_RESTORE_SECONDS
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await tween.finished
	if outcome_tween != tween:
		return
	outcome_tween = null
	outcome_layer.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if not is_active or is_concluding or not nearby_local_player:
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
	if not is_active or is_concluding or body != local_player:
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
	prompt_label.visible = (
		is_active
		and not is_concluding
		and nearby_local_player
		and not dialogue_bubble.visible
	)
	if current_stage == TowerDefenseFateManager.STAGE_VOTING:
		prompt_label.text = (
			"等待超时 · F 由房主继续结算"
			if timeout_recovery_available and local_is_host
			else "命运选择已经开启 · 剩余 %d 秒" % timeout_seconds_left
		)
	elif current_stage == TowerDefenseFateManager.STAGE_CRITICAL_BUFF_VOTING:
		prompt_label.text = (
			"全局增益投票超时 · F 由房主继续结算"
			if timeout_recovery_available and local_is_host
			else "请选择一项全局增益 · 剩余 %d 秒" % timeout_seconds_left
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


func _prepare_conclusion() -> void:
	if is_concluding:
		return
	is_concluding = true
	nearby_local_player = false
	prompt_label.visible = false
	dialogue_bubble.hide_bubble()
	interaction_shape.set_deferred("disabled", true)
	interaction_area.set_deferred("monitoring", false)


func _hide_outcome_immediately() -> void:
	if outcome_tween != null:
		outcome_tween.kill()
		outcome_tween = null
	outcome_root.modulate = Color.WHITE
	outcome_shade.modulate = Color.WHITE
	outcome_label.modulate = Color.WHITE
	outcome_layer.visible = false


func _stop_scene_transition_tween() -> void:
	if scene_transition_tween == null:
		return
	scene_transition_tween.kill()
	scene_transition_tween = null


func _set_scene_transition_progress(progress: float) -> void:
	scene_transition_progress = clampf(progress, 0.0, 1.0)
	scene_transition_cover.set_instance_shader_parameter(
		&"cover_progress",
		scene_transition_progress
	)


func _finish_scene_reveal() -> void:
	_set_scene_transition_progress(0.0)
	scene_transition_cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scene_transition_layer.visible = false


func _update_interaction_ui_position() -> void:
	interaction_ui_anchor.position = (
		xiaocong_sprite.get_global_transform_with_canvas().origin.round()
	)


func _to_int_array(value: Variant) -> Array[int]:
	var result: Array[int] = []
	if value is Array or value is PackedInt32Array:
		for entry in value:
			result.append(int(entry))
	return result
