extends SceneTree

var failures: Array[String] = []


func _init() -> void:
	var request := DamageRequest.new(17, CombatTypes.DamageType.MAGIC)
	request.with_stable_source(41, 9001, &"data_projectile")
	request.with_directions(Vector2.LEFT, Vector2.RIGHT)

	_expect(request.source == null, "Stable data sources must not require a fake Node.")
	_expect(request.source_enemy_id == 41, "Enemy identity must remain explicit.")
	_expect(request.source_projectile_id == 9001, "Projectile identity must remain explicit.")
	_expect(request.source_id == 9001, "Legacy source_id must project the projectile identity.")
	_expect(request.source_type == &"data_projectile", "Source type must remain stable.")
	_expect(request.damage_type == CombatTypes.DamageType.MAGIC, "Damage type must remain stable.")

	var result := DamageResolver.resolve(
		request,
		DamageTargetProfile.new(100, 0, 0)
	)
	_expect(result.accepted, "A stable Node-free source must resolve damage normally.")
	_expect(result.applied_damage == 17, "Stable source metadata must not change damage.")
	_expect(result.request == request, "Damage results must retain the original source contract.")

	var enemy_only := DamageRequest.new(1)
	enemy_only.with_stable_source(77, 0, &"enemy_contact")
	_expect(enemy_only.source_id == 77, "Enemy identity must backfill source_id without a projectile.")

	var legacy_node := Node.new()
	var legacy := DamageRequest.new(1).with_source(legacy_node, 12, &"legacy")
	_expect(
		legacy.source == legacy_node
		and legacy.source_id == 12
		and legacy.source_enemy_id == 0
		and legacy.source_projectile_id == 0,
		"The legacy Node source path must remain unchanged."
	)
	legacy_node.free()

	var payload := {
		"schema_version": 1,
		"valid": failures.is_empty(),
		"verdict": "passed" if failures.is_empty() else "failed",
		"violations": failures,
	}
	print("DAMAGE_REQUEST_STABLE_SOURCE_RESULT ", JSON.stringify(payload))
	if failures.is_empty():
		print("DAMAGE_REQUEST_STABLE_SOURCE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
