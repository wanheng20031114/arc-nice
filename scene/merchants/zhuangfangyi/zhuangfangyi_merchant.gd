extends Node2D
class_name ZhuangfangyiMerchant

const SKILL1_UPGRADE_INTRO_LINE := "如果有足够的息壤，我可以为你提供全新的升级。"
const SKILL1_UPGRADE_OFFER_FORMAT := "是否要花费[color=#1a8a3e]%d息壤[/color]升级 %s ？"
const ADMIN_DOLL_UPGRADE_INTRO_LINE := "听说你有管理员人偶，我可以帮你升级技能。"
const ADMIN_DOLL_UPGRADE_OFFER_FORMAT := "是否要[color=#55e68a]免费[/color]升级 %s ？"
const INSUFFICIENT_XIRANG_LINE := "息壤不足。"
const UPGRADED_LINE := "升级完成，所需技力降低了。"
const MAX_UPGRADED_LINE := "这个技能已经升级到最高等级了。"
const PLAYER_COLLISION_MASK := 2
const BODY_PUSH_QUERY_MAX_RESULTS := 16
const BODY_PUSH_DISTANCE := 24.0

@onready var collision_shape: CollisionShape2D = $StaticBody2D/CollisionShape2D
@onready var interaction_area: Area2D = $InteractionArea
@onready var dialogue_bubble: MerchantDialogueBubble = $MerchantDialogueBubble
@onready var night_light: NightPointLight2D = $NightLight

var is_active: bool = false
var nearby_players: Dictionary = {}
var active_player: Player = null
var dialogue_index: int = 0
var purchase_result_visible: bool = false
var dialogue_lines: Array = []
var multiplayer_mode_adapter: MultiplayerModeAdapter = null


func bind_multiplayer_mode_adapter(adapter: MultiplayerModeAdapter) -> void:
	multiplayer_mode_adapter = adapter


func _ready() -> void:
	interaction_area.body_entered.connect(_on_interaction_area_body_entered)
	interaction_area.body_exited.connect(_on_interaction_area_body_exited)
	set_active(visible)


func set_active(active: bool) -> void:
	is_active = active
	night_light.set_emission_allowed(active)
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
	dialogue_lines = _build_dialogue_lines(player)
	dialogue_bubble.say(dialogue_lines[dialogue_index])


func _advance_dialogue() -> void:
	if dialogue_bubble.is_revealing:
		dialogue_bubble.finish_line()
		return

	if purchase_result_visible:
		_reset_dialogue_after_transaction()
		return

	if not dialogue_bubble.visible:
		_start_dialogue(active_player)
		return

	if dialogue_index < dialogue_lines.size() - 1:
		dialogue_index += 1
		dialogue_bubble.say(dialogue_lines[dialogue_index])
		return

	_try_upgrade_skill()


func _try_upgrade_skill() -> void:
	if active_player == null:
		return
	if (
		multiplayer_mode_adapter != null
		and multiplayer_mode_adapter.request_skill1_purchase()
	):
		return
	if active_player.is_skill1_upgrade_maxed():
		dialogue_bubble.say(MAX_UPGRADED_LINE)
		purchase_result_visible = true
		return
	var has_admin_doll := active_player.has_collectible_effect(PickupConfig.COLLECTIBLE_EFFECT_ADMIN_DOLL)
	if not active_player.try_upgrade_skill1(has_admin_doll):
		dialogue_bubble.say(INSUFFICIENT_XIRANG_LINE)
		purchase_result_visible = true
		return

	dialogue_bubble.say(UPGRADED_LINE)
	purchase_result_visible = true


func show_purchase_result(result_code: int) -> void:
	match result_code:
		MerchantPurchaseResult.SkillUpgrade.UPGRADE_SUCCESS:
			dialogue_bubble.say(UPGRADED_LINE)
		MerchantPurchaseResult.SkillUpgrade.UPGRADE_MAXED:
			dialogue_bubble.say(MAX_UPGRADED_LINE)
		MerchantPurchaseResult.SkillUpgrade.INSUFFICIENT_XIRANG:
			dialogue_bubble.say(INSUFFICIENT_XIRANG_LINE)
		_:
			dialogue_bubble.say(INSUFFICIENT_XIRANG_LINE)
	purchase_result_visible = true


func _build_dialogue_lines(player: Player) -> Array:
	if player == null:
		return []
	if player.is_skill1_upgrade_maxed():
		return [MAX_UPGRADED_LINE]
	if player.has_collectible_effect(PickupConfig.COLLECTIBLE_EFFECT_ADMIN_DOLL):
		return [
			ADMIN_DOLL_UPGRADE_INTRO_LINE,
			ADMIN_DOLL_UPGRADE_OFFER_FORMAT % _get_skill1_icon_bbcode(player),
		]
	return [
		SKILL1_UPGRADE_INTRO_LINE,
		SKILL1_UPGRADE_OFFER_FORMAT % [
			player.get_skill1_upgrade_cost(),
			_get_skill1_icon_bbcode(player),
		],
	]


func _get_skill1_icon_bbcode(player: Player) -> String:
	if player == null:
		return "技能"
	var icon_path := player.get_skill1_icon_path()
	if icon_path.is_empty():
		return player.get_skill1_display_name()
	return "[img=22]%s[/img] %s" % [icon_path, player.get_skill1_display_name()]


func _reset_dialogue_after_transaction() -> void:
	dialogue_bubble.hide_bubble()
	purchase_result_visible = false
	dialogue_index = 0
	dialogue_lines = _build_dialogue_lines(active_player)


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
