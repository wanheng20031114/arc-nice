extends Node
class_name XirangDropManager

const XIRANG_DROP_SCENE := preload("res://scene/xirang_drop.tscn")

@export_range(1, 512, 1, "or_greater") var max_active_visual_drops := 128
@export_range(1, 128, 1, "or_greater") var max_visual_spawns_per_frame := 16
@export var drop_parent_path: NodePath = ^"../EnemyContainer"

var _active_drop_ids: Dictionary = {}
var _pending_rewards: Dictionary = {}
var _flush_scheduled := false
var _total_value_requested := 0
var _total_value_spawned := 0
var _visual_spawn_budget_frame := -1
var _visual_spawns_this_frame := 0


func _ready() -> void:
	set_process(false)


func _process(_delta: float) -> void:
	set_process(false)
	_flush_pending_rewards()


func spawn_reward(
	amount: int,
	target_player: Player,
	spawn_position: Vector2,
	landing_offset: Vector2 = Vector2.ZERO
) -> bool:
	if amount <= 0 or target_player == null or not is_instance_valid(target_player):
		return false
	if get_node_or_null(drop_parent_path) == null:
		return false
	_total_value_requested += amount
	if (
		_active_drop_ids.size() < maxi(max_active_visual_drops, 1)
		and _has_visual_spawn_budget()
	):
		if _spawn_visual_drop(amount, target_player, spawn_position, landing_offset):
			_schedule_pending_flush()
			return true
	_queue_pending_reward(amount, target_player, spawn_position, landing_offset)
	_schedule_pending_flush()
	return true


func get_metrics() -> Dictionary:
	var pending_value := 0
	for target_id in _pending_rewards:
		var pending := _pending_rewards[target_id] as Dictionary
		pending_value += int(pending.get("amount", 0))
	return {
		"active_visual_drops": _active_drop_ids.size(),
		"pending_reward_groups": _pending_rewards.size(),
		"pending_value": pending_value,
		"total_value_requested": _total_value_requested,
		"total_value_spawned": _total_value_spawned,
		"visual_spawns_this_frame": _get_visual_spawns_this_frame(),
		"max_visual_spawns_per_frame": maxi(max_visual_spawns_per_frame, 1),
	}


func _spawn_visual_drop(
	amount: int,
	target_player: Player,
	spawn_position: Vector2,
	landing_offset: Vector2
) -> bool:
	var drop_parent := get_node_or_null(drop_parent_path)
	if drop_parent == null or not _has_visual_spawn_budget():
		return false
	var drop := XIRANG_DROP_SCENE.instantiate() as XirangDrop
	if drop == null:
		return false
	drop_parent.add_child(drop)
	var drop_id := drop.get_instance_id()
	_active_drop_ids[drop_id] = true
	drop.tree_exited.connect(_on_drop_tree_exited.bind(drop_id), CONNECT_ONE_SHOT)
	drop.setup(amount, target_player, spawn_position, landing_offset)
	_consume_visual_spawn_budget()
	_total_value_spawned += amount
	return true


func _queue_pending_reward(
	amount: int,
	target_player: Player,
	spawn_position: Vector2,
	landing_offset: Vector2
) -> void:
	var target_id := target_player.get_instance_id()
	var pending := _pending_rewards.get(target_id, {}) as Dictionary
	if pending.is_empty():
		pending = {
			"amount": 0,
			"target_player_ref": weakref(target_player),
			"spawn_position": spawn_position,
			"landing_offset": landing_offset,
		}
	pending["amount"] = int(pending["amount"]) + amount
	pending["target_player_ref"] = weakref(target_player)
	pending["spawn_position"] = spawn_position
	pending["landing_offset"] = landing_offset
	_pending_rewards[target_id] = pending


func _on_drop_tree_exited(drop_id: int) -> void:
	_active_drop_ids.erase(drop_id)
	_schedule_pending_flush()


func _schedule_pending_flush() -> void:
	if _flush_scheduled or _pending_rewards.is_empty() or not is_inside_tree():
		return
	_flush_scheduled = true
	set_process(true)


func _flush_pending_rewards() -> void:
	_flush_scheduled = false
	while (
		is_inside_tree()
		and _active_drop_ids.size() < maxi(max_active_visual_drops, 1)
		and not _pending_rewards.is_empty()
	):
		var target_id := int(_pending_rewards.keys()[0])
		var pending := _pending_rewards[target_id] as Dictionary
		_pending_rewards.erase(target_id)
		var target_player_ref := pending.get("target_player_ref") as WeakRef
		var requested_target: Player = null
		if target_player_ref != null:
			requested_target = target_player_ref.get_ref() as Player
		var target_player := _resolve_pending_target(requested_target)
		if target_player == null:
			# A disconnected reward target must not silently destroy the queued
			# currency. Keep the aggregate until a later visual slot release (or a
			# new reward request) gives the runtime another chance to provide a
			# valid player target.
			_pending_rewards[target_id] = pending
			return
		pending["target_player_ref"] = weakref(target_player)
		var spawn_position: Vector2 = pending.get(
			"spawn_position",
			target_player.global_position
		)
		var landing_offset: Vector2 = pending.get("landing_offset", Vector2.ZERO)
		if not _spawn_visual_drop(
			int(pending.get("amount", 0)),
			target_player,
			spawn_position,
			landing_offset
		):
			_pending_rewards[target_id] = pending
			_schedule_pending_flush()
			return
	if (
		not _pending_rewards.is_empty()
		and _active_drop_ids.size() < maxi(max_active_visual_drops, 1)
	):
		_schedule_pending_flush()


func _has_visual_spawn_budget() -> bool:
	_refresh_visual_spawn_budget_frame()
	return _visual_spawns_this_frame < maxi(max_visual_spawns_per_frame, 1)


func _consume_visual_spawn_budget() -> void:
	_refresh_visual_spawn_budget_frame()
	_visual_spawns_this_frame += 1


func _get_visual_spawns_this_frame() -> int:
	_refresh_visual_spawn_budget_frame()
	return _visual_spawns_this_frame


func _refresh_visual_spawn_budget_frame() -> void:
	var current_frame := Engine.get_process_frames()
	if _visual_spawn_budget_frame == current_frame:
		return
	_visual_spawn_budget_frame = current_frame
	_visual_spawns_this_frame = 0


func _resolve_pending_target(requested_target: Player) -> Player:
	if requested_target != null and is_instance_valid(requested_target):
		return requested_target
	var runtime := get_parent() as GameRuntimeBase
	if runtime == null:
		return null
	if runtime.player != null and is_instance_valid(runtime.player):
		return runtime.player
	for player_variant in runtime.peer_players.values():
		var player_candidate := player_variant as Player
		if player_candidate != null and is_instance_valid(player_candidate):
			return player_candidate
	return null
