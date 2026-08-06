extends Node
class_name MpCollectiblePresentationCoordinator

const COLLECTIBLE_AREA_EFFECT_SCENE := preload(
	"res://scene/collectible_area_effect.tscn"
)
const COLLECTIBLE_FROST_AREA_EFFECT_SCENE := preload(
	"res://scene/collectible_frost_area_effect.tscn"
)
const COLLECTIBLE_LIGHTNING_EFFECT_SCENE := preload(
	"res://scene/collectible_lightning_effect.tscn"
)
const COLLECTIBLE_MOON_SHIELD_VISUAL_SCENE := preload(
	"res://scene/collectible_moon_shield_visual.tscn"
)
const COLLECTIBLE_EFFECT_DEDUP_RETENTION_SECONDS := 10.0

signal rpc_broadcast_requested(method_name: StringName, args: Array)

var _runtime: CombatRuntimeBase = null
var _presentation_parent: Node2D = null
var _net_manager: NetManagerStore = null
var _net_time_origin := 0.0
var _next_effect_event_id := 1
var _processed_effect_event_ids: Dictionary = {}


func bind_runtime(
	runtime_instance: CombatRuntimeBase,
	presentation_parent_instance: Node2D,
	net_manager_instance: NetManagerStore,
	net_time_origin_seconds: float
) -> void:
	assert(runtime_instance != null, "MpCollectiblePresentationCoordinator 缺少战斗运行时。")
	assert(
		presentation_parent_instance != null,
		"MpCollectiblePresentationCoordinator 缺少世界表现父节点。"
	)
	assert(net_manager_instance != null, "MpCollectiblePresentationCoordinator 缺少 NetManager。")
	_runtime = runtime_instance
	_presentation_parent = presentation_parent_instance
	_net_manager = net_manager_instance
	_net_time_origin = net_time_origin_seconds


func unbind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	if _runtime != runtime_instance:
		return
	_runtime = null
	_presentation_parent = null
	_net_manager = null


func is_bound() -> bool:
	return (
		_runtime != null
		and is_instance_valid(_runtime)
		and _presentation_parent != null
		and is_instance_valid(_presentation_parent)
		and _net_manager != null
		and is_instance_valid(_net_manager)
	)


func broadcast_visual_effect(
	effect_type: StringName,
	spawn_position: Vector2,
	radius: float,
	color: Color,
	duration: float
) -> void:
	if not is_bound() or not _net_manager.is_host():
		return
	var effect_event_id := _take_next_effect_event_id()
	rpc_broadcast_requested.emit(
		&"net_collectible_visual_effect",
		[String(effect_type), spawn_position, radius, color, duration, effect_event_id]
	)


func broadcast_follow_visual_effect(
	effect_type: StringName,
	owner_peer_id: int,
	radius: float,
	duration: float
) -> void:
	if (
		not is_bound()
		or not _net_manager.is_host()
		or owner_peer_id <= 0
	):
		return
	var effect_event_id := _take_next_effect_event_id()
	rpc_broadcast_requested.emit(
		&"net_collectible_follow_visual_effect",
		[String(effect_type), owner_peer_id, radius, duration, effect_event_id]
	)


func receive_visual_effect(
	effect_type: String,
	spawn_position: Vector2,
	radius: float,
	color: Color,
	duration: float,
	effect_event_id: int
) -> void:
	if not is_bound() or not _accept_effect_event(effect_event_id):
		return
	_spawn_world_visual_effect(
		effect_type,
		spawn_position,
		radius,
		color,
		duration
	)


func receive_follow_visual_effect(
	effect_type: String,
	owner_peer_id: int,
	radius: float,
	duration: float,
	effect_event_id: int
) -> void:
	if not is_bound() or not _accept_effect_event(effect_event_id):
		return
	_spawn_follow_visual_effect(
		effect_type,
		owner_peer_id,
		radius,
		duration
	)


func prune_recent_effect_events(now: float) -> void:
	var expired_event_ids: Array = []
	for event_id in _processed_effect_event_ids:
		if float(_processed_effect_event_ids[event_id]) <= now:
			expired_event_ids.append(event_id)
	for event_id in expired_event_ids:
		_processed_effect_event_ids.erase(event_id)


func clear_peer(peer_id: int) -> void:
	if not is_bound() or peer_id <= 0:
		return
	var owner_player: Player = _runtime.get_player_for_peer(peer_id)
	_clear_player_follow_visuals(owner_player)


func reset_session_state() -> void:
	_next_effect_event_id = 1
	_processed_effect_event_ids.clear()
	if _presentation_parent != null and is_instance_valid(_presentation_parent):
		for child in _presentation_parent.get_children():
			if (
				child is CollectibleLightningEffect
				or child is CollectibleAreaEffect
				or child is CollectibleFrostAreaEffect
			):
				child.queue_free()
	if _runtime == null or not is_instance_valid(_runtime):
		return
	for player_variant in _runtime.peer_players.values():
		_clear_player_follow_visuals(player_variant as Player)


func _take_next_effect_event_id() -> int:
	var effect_event_id := _next_effect_event_id
	_next_effect_event_id += 1
	return effect_event_id


func _accept_effect_event(effect_event_id: int) -> bool:
	if effect_event_id <= 0:
		return true
	var now := _get_net_time()
	var expires_at_variant: Variant = _processed_effect_event_ids.get(
		effect_event_id
	)
	if expires_at_variant != null:
		var expires_at := float(expires_at_variant)
		if expires_at > now:
			return false
		_processed_effect_event_ids.erase(effect_event_id)
	_processed_effect_event_ids[effect_event_id] = (
		now + COLLECTIBLE_EFFECT_DEDUP_RETENTION_SECONDS
	)
	return true


func _spawn_world_visual_effect(
	effect_type: String,
	spawn_position: Vector2,
	radius: float,
	color: Color,
	duration: float
) -> void:
	match effect_type:
		"lightning":
			var lightning := (
				COLLECTIBLE_LIGHTNING_EFFECT_SCENE.instantiate()
				as CollectibleLightningEffect
			)
			if lightning == null:
				return
			lightning.top_level = true
			lightning.setup(duration)
			_presentation_parent.add_child(lightning)
			lightning.global_position = spawn_position
		"area":
			var area := (
				COLLECTIBLE_AREA_EFFECT_SCENE.instantiate()
				as CollectibleAreaEffect
			)
			if area == null:
				return
			area.top_level = true
			area.setup(radius, color, duration)
			_presentation_parent.add_child(area)
			area.global_position = spawn_position
		"frost_area":
			var frost_area := (
				COLLECTIBLE_FROST_AREA_EFFECT_SCENE.instantiate()
				as CollectibleFrostAreaEffect
			)
			if frost_area == null:
				return
			frost_area.top_level = true
			frost_area.setup(radius, duration)
			_presentation_parent.add_child(frost_area)
			frost_area.global_position = spawn_position


func _spawn_follow_visual_effect(
	effect_type: String,
	owner_peer_id: int,
	radius: float,
	duration: float
) -> void:
	if owner_peer_id <= 0:
		return
	var owner_player: Player = _runtime.get_player_for_peer(owner_peer_id)
	if owner_player == null or not is_instance_valid(owner_player):
		return
	match effect_type:
		"moon_shield":
			var moon_shield := (
				COLLECTIBLE_MOON_SHIELD_VISUAL_SCENE.instantiate()
				as CollectibleMoonShieldVisual
			)
			if moon_shield == null:
				return
			moon_shield.setup(radius, duration)
			owner_player.add_child(moon_shield)
			moon_shield.position = Vector2.ZERO


func _clear_player_follow_visuals(owner_player: Player) -> void:
	if owner_player == null or not is_instance_valid(owner_player):
		return
	for child in owner_player.get_children():
		if child is CollectibleMoonShieldVisual:
			child.queue_free()


func _get_net_time() -> float:
	return Time.get_ticks_msec() / 1000.0 - _net_time_origin
