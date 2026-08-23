extends RefCounted
class_name EnemyDefeatContext

## Stable lethal attribution retained before Enemy._die() publishes rewards,
## drops and the existing defeated signal.

var source_snapshot: DamageSourceSnapshot = null
var damage_type: int = CombatTypes.DamageType.PHYSICAL
var damage_flags: int = 0
var resolved_damage: int = 0
var applied_damage: int = 0


static func from_damage_result(result: DamageResult) -> EnemyDefeatContext:
	if result == null or not result.lethal or result.request == null:
		return null
	var context := EnemyDefeatContext.new()
	context.source_snapshot = (
		result.request.get_or_create_source_snapshot().duplicate_snapshot()
	)
	context.damage_type = result.request.damage_type
	context.damage_flags = result.request.flags
	context.resolved_damage = result.resolved_damage
	context.applied_damage = result.applied_damage
	return context


func duplicate_context() -> EnemyDefeatContext:
	var copy := EnemyDefeatContext.new()
	copy.source_snapshot = (
		source_snapshot.duplicate_snapshot()
		if source_snapshot != null
		else null
	)
	copy.damage_type = damage_type
	copy.damage_flags = damage_flags
	copy.resolved_damage = resolved_damage
	copy.applied_damage = applied_damage
	return copy


func is_player_reward_eligible() -> bool:
	return source_snapshot != null and source_snapshot.is_player_allied()
