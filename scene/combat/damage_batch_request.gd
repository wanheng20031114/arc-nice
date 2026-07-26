extends DamageRequest
class_name DamageBatchRequest

## Ordered multi-hit input. The paired arrays live on the request so a
## DamageResult always retains enough intent to audit or deterministically
## replay the settlement, including rejected batches.
var damage_amounts: PackedInt32Array = PackedInt32Array()
var hit_counts: PackedInt32Array = PackedInt32Array()


func _init(
	initial_damage_amounts: PackedInt32Array = PackedInt32Array(),
	initial_hit_counts: PackedInt32Array = PackedInt32Array(),
	initial_damage_type: int = CombatTypes.DamageType.PHYSICAL
) -> void:
	super(0, initial_damage_type)
	damage_amounts = initial_damage_amounts.duplicate()
	hit_counts = initial_hit_counts.duplicate()
	amount = get_requested_amount()


func get_group_count() -> int:
	return mini(damage_amounts.size(), hit_counts.size())


func get_requested_amount() -> int:
	var requested_amount := 0
	for group_index in range(get_group_count()):
		var raw_damage := damage_amounts[group_index]
		var requested_count := hit_counts[group_index]
		if raw_damage > 0 and requested_count > 0:
			requested_amount += raw_damage * requested_count
	return requested_amount


func get_requested_hit_count() -> int:
	var requested_hit_count := 0
	for group_index in range(get_group_count()):
		if damage_amounts[group_index] > 0 and hit_counts[group_index] > 0:
			requested_hit_count += hit_counts[group_index]
	return requested_hit_count
