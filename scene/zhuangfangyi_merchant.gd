extends Node2D
class_name ZhuangfangyiMerchant

const DIALOGUE_LINES := [
	"你好，我是终末地的庄方宜",
	"终末地的鹈鹕已经被我发配到北部禁区",
	"我可以使用息壤帮助你强化能力",
	"是否要花费[color=#1a8a3e]200息壤[/color]购买 [img=22]res://resources/texture/weishidaier_skill1_icon.png[/img] ？",
]
const PURCHASE_COST := 200
const INSUFFICIENT_XIRANG_LINE := "息壤不足。"
const ALREADY_PURCHASED_LINE := "你已经掌握这个技能了。"
const PURCHASED_LINE := "交易完成，技能已经交给你了。"
const PLAYER_COLLISION_MASK := 2
const BODY_PUSH_QUERY_MAX_RESULTS := 16
const BODY_PUSH_DISTANCE := 24.0

@onready var collision_shape: CollisionShape2D = $StaticBody2D/CollisionShape2D
@onready var interaction_area: Area2D = $InteractionArea
@onready var dialogue_bubble: MerchantDialogueBubble = $MerchantDialogueBubble

var is_active: bool = false
var nearby_players: Dictionary = {}
var active_player: Player = null
var dialogue_index: int = 0
var purchase_result_visible: bool = false


func _ready() -> void:
	interaction_area.body_entered.connect(_on_interaction_area_body_entered)
	interaction_area.body_exited.connect(_on_interaction_area_body_exited)
	set_active(visible)


func set_active(active: bool) -> void:
	is_active = active
	visible = active
	interaction_area.set_deferred("monitoring", active)

	if not active:
		collision_shape.set_deferred("disabled", true)
		nearby_players.clear()
		active_player = null
		dialogue_bubble.hide_bubble()
		return

	collision_shape.set_deferred("disabled", false)
	call_deferred("_push_overlapping_players_out")


func _unhandled_input(event: InputEvent) -> void:
	if not is_active:
		return
	if active_player == null:
		return
	if not event.is_action_pressed("interact"):
		return

	get_viewport().set_input_as_handled()
	_advance_dialogue()


func _start_dialogue(player: Player) -> void:
	if not is_active or player == null:
		return
	active_player = player
	dialogue_index = 0
	purchase_result_visible = false
	dialogue_bubble.say(DIALOGUE_LINES[dialogue_index])


func _advance_dialogue() -> void:
	if dialogue_bubble.is_revealing:
		dialogue_bubble.finish_line()
		return

	if purchase_result_visible:
		dialogue_bubble.hide_bubble()
		purchase_result_visible = false
		return

	if dialogue_index < DIALOGUE_LINES.size() - 1:
		dialogue_index += 1
		dialogue_bubble.say(DIALOGUE_LINES[dialogue_index])
		return

	_try_purchase_skill()


func _try_purchase_skill() -> void:
	if active_player == null:
		return
	var net_manager := get_node_or_null("/root/NetManager")
	var current_scene := get_tree().current_scene
	if (
		net_manager != null
		and net_manager.is_multiplayer_active()
		and current_scene != null
		and current_scene.has_method("request_multiplayer_skill1_purchase")
	):
		current_scene.call("request_multiplayer_skill1_purchase")
		return
	if active_player.has_skill1():
		dialogue_bubble.say(ALREADY_PURCHASED_LINE)
		purchase_result_visible = true
		return
	if not active_player.try_purchase_skill1(PURCHASE_COST):
		dialogue_bubble.say(INSUFFICIENT_XIRANG_LINE)
		purchase_result_visible = true
		return

	dialogue_bubble.say(PURCHASED_LINE)
	purchase_result_visible = true


func show_purchase_result(result_code: int) -> void:
	match result_code:
		Game.PURCHASE_RESULT_SUCCESS:
			dialogue_bubble.say(PURCHASED_LINE)
		Game.PURCHASE_RESULT_ALREADY_OWNED:
			dialogue_bubble.say(ALREADY_PURCHASED_LINE)
		Game.PURCHASE_RESULT_INSUFFICIENT_XIRANG:
			dialogue_bubble.say(INSUFFICIENT_XIRANG_LINE)
		_:
			dialogue_bubble.say(INSUFFICIENT_XIRANG_LINE)
	purchase_result_visible = true


func _on_interaction_area_body_entered(body: Node2D) -> void:
	var player := body as Player
	if player == null:
		return
	if not player.uses_local_input:
		return
	nearby_players[player.get_instance_id()] = player
	if active_player == null:
		_start_dialogue(player)


func _on_interaction_area_body_exited(body: Node2D) -> void:
	var player := body as Player
	if player == null:
		return
	nearby_players.erase(player.get_instance_id())
	if player != active_player:
		return

	active_player = _pick_nearby_player()
	if active_player == null:
		dialogue_bubble.hide_bubble()
	else:
		_start_dialogue(active_player)


func _push_overlapping_players_out() -> void:
	if not is_active:
		return
	var shape := collision_shape.shape
	if shape == null:
		return

	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = shape
	query.transform = collision_shape.global_transform
	query.collision_mask = PLAYER_COLLISION_MASK
	query.collide_with_bodies = true
	query.collide_with_areas = false

	var results := get_world_2d().direct_space_state.intersect_shape(
		query,
		BODY_PUSH_QUERY_MAX_RESULTS
	)
	for result in results:
		var player := result.get("collider") as Player
		if player == null:
			continue
		var push_direction := collision_shape.global_position.direction_to(player.global_position)
		if push_direction == Vector2.ZERO:
			push_direction = Vector2.DOWN
		player.global_position = collision_shape.global_position + push_direction * BODY_PUSH_DISTANCE


func _pick_nearby_player() -> Player:
	for player in nearby_players.values():
		if is_instance_valid(player):
			return player as Player
	return null
