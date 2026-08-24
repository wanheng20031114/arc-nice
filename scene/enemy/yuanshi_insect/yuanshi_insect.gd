extends "res://scene/enemy/simple_chase_layered_enemy.gd"
class_name YuanshiInsect

# 寻路路径刷新间隔。多只敌人共享 GridPathfinder，但各自按这个节奏更新目标路径。
@export var path_refresh_interval: float = 0.25

# 距离当前路点小于该值时，切换到下一个路点。
@export var waypoint_arrival_distance: float = 2.0

# 足够接近玩家时直接追踪玩家当前位置，避免围绕玩家所在格子中心反复寻路。
@export var direct_chase_extra_distance: float = 2.0

func _get_navigation_move_direction(_delta: float) -> Vector2:
	return _get_safe_navigation_move_direction(
		objective_target,
		pathfinder,
		waypoint_arrival_distance
	)


# 根据水平移动方向更新贴图翻转，竖直移动时保留当前朝向。
func _update_facing(move_direction: Vector2) -> void:
	if is_zero_approx(move_direction.x):
		return
	_set_facing_from_direction(move_direction)


func _apply_multiplayer_player_damage(
	hit_player: Player,
	damage_amount: int,
	source_id: int,
	source_type: StringName,
	source_snapshot: DamageSourceSnapshot = null
) -> bool:
	if hit_player == null or hit_player.is_dead or damage_amount <= 0:
		return false
	var frozen_source_snapshot := (
		source_snapshot
		if source_snapshot != null
		else create_damage_source_snapshot(source_id, source_type)
	)
	var impact_direction := global_position.direction_to(
		hit_player.global_position
	)
	var request := DamageRequest.new(
		damage_amount,
		EnemyConfig.DamageType.PHYSICAL
	)
	request.with_source_snapshot(frozen_source_snapshot)
	request.with_directions(impact_direction, -impact_direction)
	if not CombatDamageAdmission.is_admitted(
		request,
		hit_player.get_combat_faction_id(),
		_get_damage_relation_service()
	):
		return false
	if _try_request_player_damage(
			source_id,
			hit_player.peer_id,
			damage_amount,
			source_type,
			EnemyConfig.DamageType.PHYSICAL,
			-impact_direction,
			false,
			false,
			frozen_source_snapshot
		):
		return true
	if _has_explicit_singleplayer_authority():
		hit_player.apply_combat_damage(request)
		return true
	return false


func _get_multiplayer_damage_source_id(source_suffix: int) -> int:
	var net_id := int(get_meta("net_id", get_instance_id()))
	return maxi(net_id, 1) * 1000000 + maxi(source_suffix, 0)
