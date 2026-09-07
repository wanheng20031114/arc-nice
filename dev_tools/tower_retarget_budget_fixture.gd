extends Node

class ObservedCoordinator extends TowerDefenseEnemyCoordinator:
	var visited: Dictionary[int, int] = {}
	var total_visits := 0
	func assign_enemy_targets(enemy: Enemy, _from_position: Vector2) -> void:
		var id := enemy.get_instance_id()
		visited[id] = int(visited.get(id, 0)) + 1
		total_visits += 1

var result: Dictionary = {}
var failures: Array[String] = []

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var summaries: Array[Dictionary] = []
	for hz in [30, 60, 120]:
		for count in [0, 1, 16, 36, 300, 1000]:
			var coordinator := ObservedCoordinator.new()
			coordinator._enemy_container = Node2D.new()
			coordinator._boss_container = Node2D.new()
			# No ready/simulation: exercise the production scheduler with real Enemy
			# identities, replacing only expensive target selection with observation.
			for index in count:
				coordinator._enemy_container.add_child(Enemy.new())
			var tick := 0
			var maximum_visits := 0
			while tick == 0 or coordinator.enemy_retarget_sweep_remaining > 0:
				var before := coordinator.total_visits
				coordinator.update_targets(1.0 / float(hz))
				maximum_visits = maxi(maximum_visits, coordinator.total_visits - before)
				tick += 1
				_check(tick < 10000, "Sweep cannot starve")
				if tick >= 10000:
					break
			_check(coordinator.visited.size() == count, "Every enemy receives one periodic visit")
			_check(coordinator.total_visits == count, "Periodic sweep does not duplicate enemies")
			_check(maximum_visits <= 16, "Hard per-tick ceiling remains 16")
			_check(tick <= maxi(ceili(0.6 * hz), ceili(float(count) / 16.0)), "Full refresh finishes within original interval or hard-cap limit")
			if count == 300 and hz == 60:
				_check(maximum_visits == 9, "300 enemies at 60 Hz spread into at most nine visits per tick")
				coordinator.visited.clear()
				coordinator.total_visits = 0
				coordinator.request_retarget()
				coordinator.update_targets(1.0 / 60.0)
				_check(coordinator.total_visits == 16, "Roster event starts fast sweep immediately")
				# Removing half the children during a sweep must leave cursor safe;
				# the following complete sweep covers every survivor without starvation.
				for index in 150:
					coordinator._enemy_container.get_child(0).free()
				for frame in 100:
					coordinator.update_targets(1.0 / 60.0)
				for child in coordinator._enemy_container.get_children():
					_check(coordinator.visited.has(child.get_instance_id()), "Survivor stays reachable after removals")
			summaries.append({"hz": hz, "enemies": count, "ticks": tick, "max_per_tick": maximum_visits})
			coordinator._enemy_container.free()
			coordinator._boss_container.free()
			coordinator.free()
	print("TOWER_RETARGET_BUDGET_REGRESSION ", JSON.stringify({"failures": failures, "sweeps": summaries}))
	result["exit_code"] = 0 if failures.is_empty() else 1
	queue_free()

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
