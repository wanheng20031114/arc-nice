extends Node

## Real authored combat scenes and production indexes; AI is disabled so this
## fixture can compare exact query semantics without motion between calls.
var result: Dictionary = {}
var _failures: Array[String] = []
var _assertions := 0
var _runtime: TowerDefenseGame
var _facade: CombatQueryFacade
var _enemies: Array[Enemy] = []
var _plants: Array[PlantDefense] = []

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	_runtime = TowerDefenseGame.new()
	_facade = _runtime.get_combat_query_facade()
	var enemy_scene := load("res://scene/enemy/enemy.tscn") as PackedScene
	for index in 300:
		var enemy := enemy_scene.instantiate() as Enemy
		enemy.process_mode = Node.PROCESS_MODE_DISABLED
		enemy.position = Vector2((index % 25) * 20, (index / 25) * 20)
		add_child(enemy)
		_runtime.combat_target_index.register_enemy(300 - index, enemy)
		_enemies.append(enemy)
	var relations := _runtime.combat_relation_service
	var ordered: Array[Node2D] = []
	var unordered: Array[Node2D] = []
	for source in [-1, 0, 1, 2, 3, 31, 32]:
		for radius in [-1.0, 0.0, 35.0, 200.0, 10000.0, INF]:
			_check_radius(Vector2(100, 100), radius, source, relations)
			_check_aabb(Rect2(-20, -20, 1000, 1000), source, relations)
	_facade.query_hostile_radius_into(Vector2.ZERO, 10000, 2, ordered, null, 0, relations)
	_check(ordered.is_empty(), "Wave enemies must not target their own cohort")
	_facade.query_hostile_radius_into(Vector2.ZERO, 10000, 1, ordered, null, 0, relations)
	_check(ordered.size() == 300, "Player faction still sees the full hostile cohort")
	# Directed relation mutations and index faction migrations are visible within
	# the same frame; no cached relation may hide newly hostile targets.
	_check(_enemies[0].set_combat_faction_id(31, -1, true), "Faction 31 migration")
	relations.set_hostile(3, 31, true)
	_check_radius(Vector2.ZERO, 20, 3, relations)
	_facade.query_hostile_radius_into(Vector2.ZERO, 10000, 3, ordered, null, 0, relations)
	_check(ordered == [_enemies[0]], "New directed hostility takes effect immediately")
	_facade.query_hostile_radius_into(Vector2.ZERO, 10000, 31, ordered, null, 0, relations)
	_check(ordered.is_empty(), "Directed hostility must not become reciprocal")
	relations.set_hostile(3, 31, false)
	_facade.query_hostile_radius_into(Vector2.ZERO, 10000, 3, ordered, null, 0, relations)
	_check(ordered.is_empty(), "Removed relation takes effect immediately")
	_check(_enemies[0].set_combat_faction_id(2, -1, true), "Migrate last member out")
	_check(not _runtime.combat_target_index.faction_buckets.has(31), "Empty faction partition removed")
	relations.set_hostile(3, 31, true)
	_enemies[0].set_combat_faction_id(31, -1, true)
	_enemies[0].global_position = Vector2(5000, 5000)
	_check_radius(Vector2(5000, 5000), 50, 3, relations)
	_check_radius(Vector2.ZERO, 50, 3, relations)
	_check_aabb(Rect2(4900, 4900, 200, 200), 3, relations)
	_enemies[0].is_dead = true
	_check_radius(Vector2(5000, 5000), 50, 3, relations)
	_enemies[1].queue_free()
	_check_radius(Vector2.ZERO, 10000, 1, relations)
	# Cross-kind ties use actual Player and PlantDefense nodes, preserving the
	# public player -> plant -> enemy / stable-ID order after linear selection.
	var player_scene := load("res://scene/player/weishidaier/player_weishidaier.tscn") as PackedScene
	var player := player_scene.instantiate() as Player
	player.process_mode = Node.PROCESS_MODE_DISABLED
	player.position = Vector2(-10, 0)
	add_child(player)
	_runtime.player = player
	var fence_scene := load("res://scene/plant_defense/simple_fence.tscn") as PackedScene
	for index in 2:
		var plant := fence_scene.instantiate() as PlantDefense
		plant.process_mode = Node.PROCESS_MODE_DISABLED
		plant.position = Vector2(0, 10 if index == 0 else -10)
		plant.set_meta(&"net_id", 20 - index)
		add_child(plant)
		_plants.append(plant)
	_facade.bind_plant_query_port(_resolve_plant, _query_plants, _query_plants_aabb)
	relations.set_hostile(3, 1, true)
	relations.set_hostile(3, 2, true)
	_enemies[2].global_position = Vector2(10, 0)
	_enemies[3].global_position = Vector2(10, 0)
	_facade.query_hostile_radius_into(Vector2.ZERO, 11, 3, ordered, null, 0, relations)
	_check(ordered.size() == 5, "Mixed equal-distance candidate cohort")
	_check(ordered[0] == player and ordered[1] == _plants[1] and ordered[2] == _plants[0], "Cross-kind and plant stable-ID tie order")
	var excluded := {}
	for expected in ordered:
		var nearest := _runtime.find_nearest_hostile_enemy_attack_target_world(Vector2.ZERO, 11, 3, excluded)
		_check(nearest == expected, "Linear nearest preserves ordered selection with exclusions")
		excluded[expected.get_instance_id()] = true
	_check(_runtime.find_nearest_hostile_enemy_attack_target_world(Vector2.ZERO, 11, 3, excluded) == null, "Every candidate excluded yields null")
	_plants[1].is_removing = true
	player.is_dead = true
	_check_radius(Vector2.ZERO, 11, 3, relations)
	for radius in [0.0, 11.0, 35.0, 200.0, 10000.0]:
		_check_radius(Vector2.ZERO, radius, 3, relations)
		_facade.query_hostile_radius_into(Vector2.ZERO, radius, 3, ordered, null, 2, relations)
		_check(ordered.size() <= 2, "Public count limit preserved")
		_facade.query_hostile_radius_unordered_into(Vector2.ZERO, radius, 3, unordered, _enemies[2], relations)
		_check(not unordered.has(_enemies[2]), "Excluded enemy remains excluded")
	var timings := {}
	for mode in ["ordered_nearest", "linear_nearest", "no_hostile_partition"]:
		var start := Time.get_ticks_usec()
		for iteration in 200:
			if mode == "ordered_nearest":
				_facade.query_hostile_radius_into(Vector2.ZERO, 10000, 1, ordered, null, 0, relations)
			elif mode == "linear_nearest":
				_runtime.find_nearest_hostile_enemy_attack_target_world(Vector2.ZERO, 10000, 1)
			else:
				_facade.query_hostile_radius_unordered_into(Vector2.ZERO, 10000, 2, unordered, null, relations, false, false, true)
			timings[mode + "_200_usec"] = Time.get_ticks_usec() - start
	_runtime.combat_target_index.clear()
	_facade.clear_plant_query_port()
	_facade.bind_runtime(null)
	_runtime.free()
	_runtime = null
	_facade = null
	print("HOSTILE_QUERY_REGRESSION ", JSON.stringify({"assertions": _assertions, "failures": _failures, "timings": timings}))
	result["exit_code"] = 0 if _failures.is_empty() else 1
	queue_free()

func _check_radius(center: Vector2, radius: float, source: int, relations: CombatRelationService) -> void:
	var ordered: Array[Node2D] = []
	var unordered: Array[Node2D] = []
	_facade.query_hostile_radius_into(center, radius, source, ordered, null, 0, relations)
	_facade.query_hostile_radius_unordered_into(center, radius, source, unordered, null, relations)
	_check(_ids(ordered) == _ids(unordered), "Ordered/unordered radius candidate sets match")
	var reference: Array[Node2D] = []
	if radius >= 0 and is_finite(radius) and center.is_finite():
		for enemy in _enemies:
			if CombatTargetIndex.is_enemy_queryable(enemy) and relations.is_hostile(source, enemy.get_combat_faction_id()) and center.distance_squared_to(enemy.global_position) <= radius * radius:
				reference.append(enemy)
		for target in _plants:
			if not target.is_dead and not target.is_removing and not target.is_queued_for_deletion() and relations.is_hostile(source, 1) and center.distance_squared_to(target.global_position) <= radius * radius:
				reference.append(target)
		if _runtime.player != null and not _runtime.player.is_dead and relations.is_hostile(source, 1) and center.distance_squared_to(_runtime.player.global_position) <= radius * radius:
			reference.append(_runtime.player)
	_check(_ids(ordered) == _ids(reference), "Indexed query matches independent live-registry reference")
	for i in range(1, ordered.size()):
		_check(not _facade.is_radius_candidate_before(ordered[i], ordered[i - 1], center), "Distance/kind/stable-ID order remains monotonic")

func _check_aabb(bounds: Rect2, source: int, relations: CombatRelationService) -> void:
	var actual: Array[Enemy] = []
	_runtime.combat_target_index.query_hostile_world_aabb_unordered_into(bounds, source, actual, null, relations)
	var reference: Array[Node2D] = []
	var actual_nodes: Array[Node2D] = []
	for enemy in actual:
		actual_nodes.append(enemy)
	for enemy in _enemies:
		if CombatTargetIndex.is_enemy_queryable(enemy) and relations.is_hostile(source, enemy.get_combat_faction_id()) and bounds.has_point(enemy.global_position):
			reference.append(enemy)
	_check(_ids(actual_nodes) == _ids(reference), "Hostile AABB matches registry reference")

func _ids(targets: Array[Node2D]) -> Array[int]:
	var ids: Array[int] = []
	for target in targets:
		ids.append(target.get_instance_id())
	ids.sort()
	return ids

func _resolve_plant(net_id: int) -> PlantDefense:
	for plant in _plants:
		if int(plant.get_meta(&"net_id")) == net_id:
			return plant
	return null

func _query_plants(center: Vector2, radius: float, output: Array[PlantDefense]) -> void:
	output.clear()
	for plant in _plants:
		if center.distance_squared_to(plant.global_position) <= radius * radius:
			output.append(plant)

func _query_plants_aabb(bounds: Rect2, output: Array[PlantDefense]) -> void:
	output.clear()
	for plant in _plants:
		if bounds.has_point(plant.global_position):
			output.append(plant)

func _check(condition: bool, message: String) -> void:
	_assertions += 1
	if not condition:
		_failures.append(message)
		push_error(message)
