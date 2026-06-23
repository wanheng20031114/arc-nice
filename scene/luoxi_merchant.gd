extends Node2D
class_name LuoxiMerchant

const APPLE_COLLECTIBLE := preload("res://resources/config/pickups/collectible_apple.tres")
const APPLE_ICON_BBCODE := "[img=18]res://resources/texture/apple_collectible.png[/img]"
const GOLD_WINE_CUP_COLLECTIBLE := preload("res://resources/config/pickups/collectible_gold_wine_cup.tres")
const TIANSHI_STAKE_COLLECTIBLE := preload("res://resources/config/pickups/collectible_tianshi_stake.tres")
const RUBY_COLLECTIBLE := preload("res://resources/config/pickups/collectible_ruby.tres")
const EMERALD_COLLECTIBLE := preload("res://resources/config/pickups/collectible_emerald.tres")
const TOPAZ_COLLECTIBLE := preload("res://resources/config/pickups/collectible_topaz.tres")
const GRAY_GEM_COLLECTIBLE := preload("res://resources/config/pickups/collectible_gray_gem.tres")
const AMETHYST_COLLECTIBLE := preload("res://resources/config/pickups/collectible_amethyst.tres")
const POWER_RING_COLLECTIBLE := preload("res://resources/config/pickups/collectible_power_ring.tres")
const LIFE_RING_COLLECTIBLE := preload("res://resources/config/pickups/collectible_life_ring.tres")
const SPEED_RING_COLLECTIBLE := preload("res://resources/config/pickups/collectible_speed_ring.tres")
const PHYSICAL_RING_COLLECTIBLE := preload("res://resources/config/pickups/collectible_physical_ring.tres")
const MAGIC_RING_COLLECTIBLE := preload("res://resources/config/pickups/collectible_magic_ring.tres")
const MOON_AMULET_COLLECTIBLE := preload("res://resources/config/pickups/collectible_moon_amulet.tres")
const THUNDER_CRYSTAL_COLLECTIBLE := preload("res://resources/config/pickups/collectible_thunder_crystal.tres")
const FROST_CRYSTAL_COLLECTIBLE := preload("res://resources/config/pickups/collectible_frost_crystal.tres")
const LIFE_CRYSTAL_COLLECTIBLE := preload("res://resources/config/pickups/collectible_life_crystal.tres")
const SWIFT_CRYSTAL_COLLECTIBLE := preload("res://resources/config/pickups/collectible_swift_crystal.tres")
const ADMIN_DOLL_COLLECTIBLE := preload("res://resources/config/pickups/collectible_admin_doll.tres")
const COLLECTIBLE_POOL := [
	APPLE_COLLECTIBLE,
	GOLD_WINE_CUP_COLLECTIBLE,
	TIANSHI_STAKE_COLLECTIBLE,
	RUBY_COLLECTIBLE,
	EMERALD_COLLECTIBLE,
	TOPAZ_COLLECTIBLE,
	GRAY_GEM_COLLECTIBLE,
	AMETHYST_COLLECTIBLE,
	POWER_RING_COLLECTIBLE,
	LIFE_RING_COLLECTIBLE,
	SPEED_RING_COLLECTIBLE,
	PHYSICAL_RING_COLLECTIBLE,
	MAGIC_RING_COLLECTIBLE,
	MOON_AMULET_COLLECTIBLE,
	THUNDER_CRYSTAL_COLLECTIBLE,
	FROST_CRYSTAL_COLLECTIBLE,
	LIFE_CRYSTAL_COLLECTIBLE,
	SWIFT_CRYSTAL_COLLECTIBLE,
	ADMIN_DOLL_COLLECTIBLE,
]
const DIALOGUE_LINES := [
	"我是终末地的爪牙！",
	"我能为你提供收藏品来强化自己。",
]
const CHOICE_COUNT := 3
const CLAIMED_LINE := "这个回合我已经把收藏品交给你了。"
const SUCCESS_LINE := "拿好收藏品，可别小看它。"
const ALREADY_CLAIMED_LINE := "这个回合只能选择一次收藏品。"
const INVENTORY_FULL_LINE := "背包已经满了，无法再继续获得收藏品。"
const INVALID_PLAYER_LINE := "现在还不能把收藏品交给你。"
const PLAYER_COLLISION_MASK := 2
const BODY_PUSH_QUERY_MAX_RESULTS := 16
const BODY_PUSH_DISTANCE := 22.0

const COLLECTIBLE_RESULT_SUCCESS := 0
const COLLECTIBLE_RESULT_ALREADY_CLAIMED := 1
const COLLECTIBLE_RESULT_INVENTORY_FULL := 2
const COLLECTIBLE_RESULT_INVALID_PLAYER := 3

@onready var collision_shape: CollisionShape2D = $StaticBody2D/CollisionShape2D
@onready var interaction_area: Area2D = $InteractionArea
@onready var dialogue_bubble: MerchantDialogueBubble = $MerchantDialogueBubble
@onready var choice_overlay: LuoxiCollectibleChoiceOverlay = $LuoxiCollectibleChoiceOverlay

var is_active: bool = false
var nearby_players: Dictionary = {}
var active_player: Player = null
var dialogue_index: int = 0
var selected_choice_index: int = 0
var choice_visible: bool = false
var result_visible: bool = false
var dialogue_lines: Array = []
var claimed_player_keys: Dictionary = {}
var pending_choices_by_player_key: Dictionary = {}


static func get_choice_count() -> int:
	return CHOICE_COUNT


static func get_collectible_pool() -> Array:
	return COLLECTIBLE_POOL.duplicate()


static func get_collectible_for_choice(choice_index: int) -> PickupConfig:
	if choice_index < 0 or choice_index >= COLLECTIBLE_POOL.size():
		return null
	return COLLECTIBLE_POOL[choice_index] as PickupConfig


static func get_collectible_for_path(config_path: String) -> PickupConfig:
	if config_path.is_empty():
		return null
	for item in COLLECTIBLE_POOL:
		var config := item as PickupConfig
		if config != null and config.resource_path == config_path:
			return config
	return null


static func is_collectible_pool_path(config_path: String) -> bool:
	return get_collectible_for_path(config_path) != null


static func get_result_line(result_code: int) -> String:
	match result_code:
		COLLECTIBLE_RESULT_SUCCESS:
			return SUCCESS_LINE
		COLLECTIBLE_RESULT_ALREADY_CLAIMED:
			return ALREADY_CLAIMED_LINE
		COLLECTIBLE_RESULT_INVENTORY_FULL:
			return INVENTORY_FULL_LINE
		_:
			return INVALID_PLAYER_LINE


func _ready() -> void:
	interaction_area.body_entered.connect(_on_interaction_area_body_entered)
	interaction_area.body_exited.connect(_on_interaction_area_body_exited)
	choice_overlay.choice_selected.connect(_on_choice_overlay_choice_selected)
	choice_overlay.choice_closed.connect(_on_choice_overlay_choice_closed)
	set_active(visible)


func set_active(active: bool) -> void:
	is_active = active
	visible = active
	interaction_area.set_deferred("monitoring", active)

	if not active:
		collision_shape.set_deferred("disabled", true)
		nearby_players.clear()
		active_player = null
		choice_visible = false
		result_visible = false
		choice_overlay.hide_choices()
		dialogue_bubble.hide_bubble()
		return

	collision_shape.set_deferred("disabled", false)
	call_deferred("_push_overlapping_players_out")


func _unhandled_input(event: InputEvent) -> void:
	if not is_active or active_player == null:
		return

	if choice_visible:
		if _handle_choice_input(event):
			get_viewport().set_input_as_handled()
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
	selected_choice_index = 0
	choice_visible = false
	result_visible = false
	choice_overlay.hide_choices()
	dialogue_lines = _build_dialogue_lines(player)
	dialogue_bubble.say(dialogue_lines[dialogue_index])


func _advance_dialogue() -> void:
	if dialogue_bubble.is_revealing:
		dialogue_bubble.finish_line()
		return

	if result_visible:
		_reset_dialogue_after_result()
		return

	if not dialogue_bubble.visible:
		_start_dialogue(active_player)
		return

	if dialogue_index < dialogue_lines.size() - 1:
		dialogue_index += 1
		dialogue_bubble.say(dialogue_lines[dialogue_index])
		return

	if _is_player_claimed(active_player):
		dialogue_bubble.hide_bubble()
		return

	_show_choice_offer()


func show_collectible_result(result_code: int) -> void:
	choice_visible = false
	result_visible = true
	choice_overlay.hide_choices()
	if result_code == COLLECTIBLE_RESULT_SUCCESS and active_player != null:
		var player_key := _get_player_claim_key(active_player)
		claimed_player_keys[player_key] = true
		pending_choices_by_player_key.erase(player_key)
	dialogue_bubble.say(get_result_line(result_code))


func _show_choice_offer() -> void:
	choice_visible = true
	dialogue_bubble.hide_bubble()
	choice_overlay.show_choices(_build_collectible_choices(), selected_choice_index)


func _handle_choice_input(event: InputEvent) -> bool:
	if choice_overlay.handle_input(event):
		selected_choice_index = choice_overlay.selected_index
		return true

	var key_event := event as InputEventKey
	if key_event == null or not key_event.pressed or key_event.echo:
		return false
	match key_event.physical_keycode:
		KEY_1:
			selected_choice_index = 0
			_try_claim_selected_collectible()
			return true
		KEY_2:
			selected_choice_index = 1
			_try_claim_selected_collectible()
			return true
		KEY_3:
			selected_choice_index = 2
			_try_claim_selected_collectible()
			return true
	return false


func _select_choice(choice_index: int) -> void:
	selected_choice_index = wrapi(choice_index, 0, CHOICE_COUNT)
	choice_overlay.select_choice(selected_choice_index)


func _try_claim_selected_collectible() -> void:
	if active_player == null:
		return
	var selected_item := _get_current_choice_item(selected_choice_index)
	if selected_item == null:
		show_collectible_result(COLLECTIBLE_RESULT_INVALID_PLAYER)
		return
	var config_path := selected_item.resource_path
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("request_luoxi_collectible_choice"):
		current_scene.call("request_luoxi_collectible_choice", selected_choice_index, config_path)
		return
	show_collectible_result(_claim_local_collectible(active_player, config_path))


func _claim_local_collectible(player: Player, config_path: String) -> int:
	if player == null:
		return COLLECTIBLE_RESULT_INVALID_PLAYER
	var player_key := _get_player_claim_key(player)
	if claimed_player_keys.has(player_key):
		return COLLECTIBLE_RESULT_ALREADY_CLAIMED
	var item := get_collectible_for_path(config_path)
	if item == null:
		return COLLECTIBLE_RESULT_INVALID_PLAYER

	var run_state := get_node_or_null("/root/RunState") as RunStateStore
	if run_state == null:
		return COLLECTIBLE_RESULT_INVALID_PLAYER
	var stored := (
		run_state.try_add_item_for_peer(player.peer_id, item)
		if player.peer_id > 0
		else run_state.try_add_item(item)
	)
	if not stored:
		return COLLECTIBLE_RESULT_INVENTORY_FULL
	claimed_player_keys[player_key] = true
	pending_choices_by_player_key.erase(player_key)
	return COLLECTIBLE_RESULT_SUCCESS


func _build_dialogue_lines(player: Player) -> Array:
	if _is_player_claimed(player):
		return [CLAIMED_LINE]
	return DIALOGUE_LINES.duplicate()


func _build_collectible_choices() -> Array:
	var player_key := _get_player_claim_key(active_player)
	if pending_choices_by_player_key.has(player_key):
		return (pending_choices_by_player_key[player_key] as Array).duplicate()

	var choices := _build_random_collectible_choices()
	pending_choices_by_player_key[player_key] = choices
	return choices.duplicate()


func _build_random_collectible_choices() -> Array:
	var choices: Array = []
	var pool := COLLECTIBLE_POOL.duplicate()
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for _choice_index in range(mini(CHOICE_COUNT, pool.size())):
		var pool_index := rng.randi_range(0, pool.size() - 1)
		choices.append(pool[pool_index])
		pool.remove_at(pool_index)
	return choices


func _get_current_choice_item(choice_index: int) -> PickupConfig:
	if choice_index < 0 or choice_index >= CHOICE_COUNT:
		return null
	var choices := _build_collectible_choices()
	if choice_index >= choices.size():
		return null
	return choices[choice_index] as PickupConfig


func _reset_dialogue_after_result() -> void:
	dialogue_bubble.hide_bubble()
	result_visible = false
	choice_visible = false
	choice_overlay.hide_choices()
	dialogue_index = 0
	dialogue_lines = _build_dialogue_lines(active_player)


func _is_player_claimed(player: Player) -> bool:
	if player == null:
		return false
	var player_key := _get_player_claim_key(player)
	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.has_method("has_luoxi_collectible_claimed"):
		return bool(current_scene.call("has_luoxi_collectible_claimed", player_key))
	return claimed_player_keys.has(player_key)


func _get_player_claim_key(player: Player) -> int:
	if player == null or player.peer_id <= 0:
		return 0
	return player.peer_id


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
		choice_visible = false
		result_visible = false
		choice_overlay.hide_choices()
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


func reset_round_collectible_claims() -> void:
	claimed_player_keys.clear()
	pending_choices_by_player_key.clear()
	if choice_visible:
		choice_visible = false
		choice_overlay.hide_choices()


func _on_choice_overlay_choice_selected(choice_index: int) -> void:
	selected_choice_index = choice_index
	_try_claim_selected_collectible()


func _on_choice_overlay_choice_closed() -> void:
	choice_visible = false
