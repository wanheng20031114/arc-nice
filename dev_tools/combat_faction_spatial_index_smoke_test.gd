extends SceneTree

const INDEX := preload("res://scene/combat/targeting/combat_target_index.gd")
const RELATIONS := preload("res://scene/combat/faction/combat_relation_service.gd")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var index := INDEX.new()
	var player_ally := _make_enemy(Vector2.ZERO, RELATIONS.PLAYER_ALLIED)
	var hostile_high_id := _make_enemy(Vector2(24.0, 0.0), RELATIONS.HOSTILE_WAVE)
	var hostile_low_id := _make_enemy(Vector2(-24.0, 0.0), RELATIONS.HOSTILE_WAVE)
	var neutral := _make_enemy(Vector2(8.0, 0.0), RELATIONS.NEUTRAL)
	var future_faction := _make_enemy(Vector2(12.0, 0.0), 3)
	index.register_enemy(40, player_ally)
	index.register_enemy(30, hostile_high_id)
	index.register_enemy(20, hostile_low_id)
	index.register_enemy(10, neutral)
	index.register_enemy(50, future_faction)

	var result: Array[Enemy] = [neutral]
	index.query_hostile_radius_into(
		Vector2.ZERO,
		64.0,
		RELATIONS.PLAYER_ALLIED,
		result
	)
	_expect(
		result == [hostile_low_id, hostile_high_id],
		"Default hostile queries must exclude neutral, friendly, and unconfigured factions and use net-id tie breaks."
	)
	_expect(
		index.find_nearest_hostile(
			Vector2.ZERO,
			64.0,
			RELATIONS.PLAYER_ALLIED
		) == hostile_low_id,
		"Nearest-hostile lookup must share the deterministic radius-query order."
	)

	var custom_relations := RELATIONS.new()
	_expect(
		custom_relations.set_hostile(3, RELATIONS.HOSTILE_WAVE),
		"A future faction must support an explicitly directed hostile relation."
	)
	index.query_hostile_radius_into(
		Vector2.ZERO,
		64.0,
		3,
		result,
		0,
		future_faction,
		custom_relations
	)
	_expect(
		result == [hostile_low_id, hostile_high_id],
		"Custom directed relations must query only configured hostile partitions."
	)

	_expect(
		hostile_low_id.set_combat_faction_id(RELATIONS.PLAYER_ALLIED),
		"Runtime faction changes must be accepted for ordinary enemies."
	)
	index.query_hostile_radius_into(
		Vector2.ZERO,
		64.0,
		RELATIONS.PLAYER_ALLIED,
		result
	)
	_expect(
		result == [hostile_high_id]
		and int(index.faction_by_net_id[20]) == RELATIONS.PLAYER_ALLIED,
		"Faction changes must migrate the existing spatial entry in O(1)."
	)
	var old_hostile_cells := index.faction_buckets.get(RELATIONS.HOSTILE_WAVE, {}) as Dictionary
	var low_cell: Vector2i = index.bucket_by_net_id[20]
	_expect(
		not old_hostile_cells.has(low_cell)
		or not (old_hostile_cells[low_cell] as Array).has(20),
		"The old faction partition must not retain a migrated net id."
	)

	var aabb_result: Array[Enemy] = [neutral]
	index.query_world_aabb_into(Rect2(Vector2(32.0, 16.0), Vector2(-64.0, -32.0)), aabb_result)
	_expect(
		aabb_result == [neutral, hostile_low_id, hostile_high_id, player_ally, future_faction],
		"AABB queries must normalize negative sizes, reuse caller storage, and sort by stable net id."
	)
	index.query_world_aabb_into(Rect2(Vector2.ZERO, Vector2.ZERO), aabb_result)
	_expect(aabb_result.is_empty(), "Degenerate AABBs must fail closed.")
	var hostile_aabb_result: Array[Enemy] = [neutral]
	index.query_hostile_world_aabb_unordered_into(
		Rect2(Vector2(32.0, 16.0), Vector2(-64.0, -32.0)),
		RELATIONS.PLAYER_ALLIED,
		hostile_aabb_result,
		player_ally
	)
	_expect(
		hostile_aabb_result == [hostile_high_id],
		"Hostile AABB broadphase must clear caller storage and exclude friendly partitions."
	)
	index.query_hostile_world_aabb_unordered_into(
		Rect2(Vector2(32.0, 16.0), Vector2(-64.0, -32.0)),
		3,
		hostile_aabb_result,
		future_faction,
		custom_relations
	)
	_expect(
		hostile_aabb_result == [hostile_high_id],
		"Hostile AABB broadphase must honor directional runtime relations without sorting."
	)

	var boss := Enemy.new()
	var boss_config := EnemyConfig.new()
	boss_config.is_boss = true
	boss.config = boss_config
	_expect(
		not boss.set_combat_faction_id(RELATIONS.PLAYER_ALLIED),
		"Boss faction changes must be locked by the common runtime API."
	)
	_expect(
		boss.apply_network_combat_faction(RELATIONS.HOSTILE_WAVE, 1),
		"Authoritative network repair must be able to apply the locked boss faction revision."
	)
	_expect(
		not boss.apply_network_combat_faction(RELATIONS.PLAYER_ALLIED, 1),
		"Equal or stale network faction revisions must be rejected."
	)

	index.clear()
	for enemy in [player_ally, hostile_high_id, hostile_low_id, neutral, future_faction, boss]:
		enemy.free()
	if failures.is_empty():
		print("COMBAT_FACTION_SPATIAL_INDEX_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _make_enemy(position: Vector2, faction_id: int) -> Enemy:
	var enemy := Enemy.new()
	enemy.position = position
	_expect(
		enemy.set_combat_faction_id(faction_id),
		"Fixture faction assignment must succeed."
	)
	return enemy


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
