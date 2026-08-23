extends SceneTree

const BASIC_ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const PLANT_COUNT := 100
const ENEMY_COUNT := 300
const REMOVED_PLANT_TARGET_COUNT := 4

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_target_change_and_coordinator_semantics()
	_test_dense_reverse_index_complexity()
	await _test_multiplayer_proxy_and_tree_exit_cleanup()
	if failures.is_empty():
		print("PLANT_OBJECTIVE_ENEMY_INDEX_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_target_change_and_coordinator_semantics() -> void:
	var coordinator := TowerDefenseEnemyCoordinator.new()
	var enemy_container := Node2D.new()
	var boss_container := Node2D.new()
	var ordinary_enemy := Enemy.new()
	var boss_enemy := Enemy.new()
	var plant_a := PlantDefense.new()
	var plant_b := PlantDefense.new()
	var home_target := Node2D.new()
	enemy_container.add_child(ordinary_enemy)
	boss_container.add_child(boss_enemy)
	coordinator._enemy_container = enemy_container
	coordinator._boss_container = boss_container

	var index: PlantObjectiveEnemyIndex = coordinator._plant_objective_enemy_index
	_expect(index.track(ordinary_enemy), "普通敌人必须能登记到建筑目标反向索引。")
	_expect(index.track(boss_enemy), "Boss 必须与普通敌人共用建筑目标反向索引。")
	for _repeat_index in range(8):
		_expect(index.track(ordinary_enemy), "同一敌人的重复 track 必须幂等成功。")
	_expect(index.get_tracked_enemy_count() == 2, "重复 track 不得制造重复敌人记录。")

	ordinary_enemy.objective_target = plant_a
	boss_enemy.set_objective_target(plant_a)
	_expect(
		index.get_targeting_enemy_count(plant_a) == 2,
		"直接属性赋值与 set_objective_target 都必须进入同一 plant 桶。"
	)
	ordinary_enemy.objective_target = plant_b
	_expect(
		index.get_targeting_enemy_count(plant_a) == 1
		and index.get_targeting_enemy_count(plant_b) == 1,
		"plant→plant 切换必须原子迁移正反向成员关系。"
	)
	ordinary_enemy.objective_target = home_target
	_expect(
		index.get_targeting_enemy_count(plant_b) == 0,
		"plant→非建筑目标必须立即释放旧 plant 桶。"
	)
	ordinary_enemy.objective_target = plant_a

	coordinator.clear_removed_plant_objective(plant_a)
	var metrics := coordinator.get_plant_objective_index_metrics()
	_expect(
		ordinary_enemy.objective_target == null and boss_enemy.objective_target == null,
		"建筑移除必须同时清空普通敌人与 Boss 的同一目标。"
	)
	_expect(
		int(metrics.get("last_take_candidate_visits", -1)) == 2,
		"协调器只能访问被移除建筑桶内的两个敌人。"
	)

	# Re-entering removal and switching to another plant from the target-changed
	# signal must be safe because the old bucket was detached before iteration.
	var reentrant_state := {"entered": false}
	ordinary_enemy.objective_target_changed.connect(
		func(_enemy: Enemy, current_target: Node2D) -> void:
			if current_target != null or bool(reentrant_state["entered"]):
				return
			reentrant_state["entered"] = true
			coordinator.clear_removed_plant_objective(plant_a)
			ordinary_enemy.objective_target = plant_b
	)
	ordinary_enemy.objective_target = plant_a
	coordinator.clear_removed_plant_objective(plant_a)
	_expect(
		bool(reentrant_state["entered"])
		and ordinary_enemy.objective_target == plant_b
		and index.get_targeting_enemy_count(plant_a) == 0
		and index.get_targeting_enemy_count(plant_b) == 1,
		(
			"同帧重入移除和目标切换必须保留新目标，且不得复活旧桶："
			+ "reentered=%s target_b=%s bucket_a=%d bucket_b=%d"
			% [
				bool(reentrant_state["entered"]),
				ordinary_enemy.objective_target == plant_b,
				index.get_targeting_enemy_count(plant_a),
				index.get_targeting_enemy_count(plant_b),
			]
		)
	)

	index.clear()
	enemy_container.free()
	boss_container.free()
	plant_a.free()
	plant_b.free()
	home_target.free()
	coordinator.free()


func _test_dense_reverse_index_complexity() -> void:
	var index := PlantObjectiveEnemyIndex.new()
	var plants: Array[PlantDefense] = []
	var enemies: Array[Enemy] = []
	for _plant_index in range(PLANT_COUNT):
		plants.append(PlantDefense.new())

	for enemy_index in range(ENEMY_COUNT):
		var enemy := Enemy.new()
		enemies.append(enemy)
		_expect(index.track(enemy), "压力样本中的敌人必须成功登记。")
		if enemy_index < REMOVED_PLANT_TARGET_COUNT:
			enemy.objective_target = plants[0]
		else:
			var unrelated_plant_index := 1 + (
				(enemy_index - REMOVED_PLANT_TARGET_COUNT) % (PLANT_COUNT - 1)
			)
			enemy.objective_target = plants[unrelated_plant_index]

	for _repeat_index in range(16):
		index.track(enemies[0])
	# Exercise a same-frame direct target switch without changing final density.
	enemies[0].objective_target = plants[1]
	enemies[0].objective_target = plants[0]
	_expect(
		index.get_tracked_enemy_count() == ENEMY_COUNT
		and index.get_plant_membership_count() == ENEMY_COUNT
		and index.get_plant_bucket_count() == PLANT_COUNT,
		"100 建筑×300 敌人压力布局必须保持一敌人一成员关系。"
	)
	_expect(
		index.get_targeting_enemy_count(plants[0]) == REMOVED_PLANT_TARGET_COUNT,
		"待移除建筑必须只拥有少量命中敌人。"
	)

	var affected_enemies := index.take_enemies_targeting_plant(plants[0])
	_expect(
		affected_enemies.size() == REMOVED_PLANT_TARGET_COUNT,
		"原子摘桶必须返回全部且仅返回真正命中的敌人。"
	)
	_expect(
		index.get_last_take_candidate_visits() == REMOVED_PLANT_TARGET_COUNT,
		(
			"100 建筑×300 敌人移除时，候选访问数必须等于被移除桶规模，"
			+ "不得退化为扫描 300 敌人。"
		)
	)
	for enemy in affected_enemies:
		enemy.set_objective_target(null)
	_expect(
		index.get_plant_membership_count()
		== ENEMY_COUNT - REMOVED_PLANT_TARGET_COUNT,
		"摘桶后的目标清空不得重复移除或破坏无关成员。"
	)

	# An entity released without a tree exit is pruned only when its own bucket is
	# accessed; no global stale-reference audit is needed.
	var stale_enemy := Enemy.new()
	index.track(stale_enemy)
	stale_enemy.objective_target = plants[0]
	stale_enemy.free()
	_expect(
		index.get_targeting_enemy_count(plants[0]) == 0
		and index.get_tracked_enemy_count() == ENEMY_COUNT,
		"相关桶访问必须精确清理失效 WeakRef。"
	)

	index.clear()
	for enemy in enemies:
		enemy.free()
	for plant in plants:
		plant.free()


func _test_multiplayer_proxy_and_tree_exit_cleanup() -> void:
	var index := PlantObjectiveEnemyIndex.new()
	var plant := PlantDefense.new()
	var enemy := BASIC_ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(enemy != null, "多人代理/脱树测试必须能实例化正式敌人场景。")
	if enemy == null:
		plant.free()
		return
	enemy.set_physics_process(false)
	root.add_child(enemy)
	index.track(enemy)
	enemy.objective_target = plant
	_expect(index.get_targeting_enemy_count(plant) == 1, "setup 前必须存在目标成员。")
	enemy.setup(BASIC_ENEMY_CONFIG, null, null, null)
	_expect(
		enemy.objective_target == null
		and index.get_targeting_enemy_count(plant) == 0,
		"setup 的默认目标写入必须同步释放旧建筑成员。"
	)
	var player_probe := Player.new()
	enemy.objective_target = plant
	enemy.set_target_player(player_probe)
	_expect(
		enemy.objective_target == plant
		and index.get_targeting_enemy_count(plant) == 1,
		"更新战斗玩家不得错误覆盖既有建筑目标。"
	)
	enemy.objective_target = null
	enemy.set_target_player(player_probe)
	_expect(
		enemy.objective_target == player_probe
		and index.get_targeting_enemy_count(plant) == 0,
		"set_target_player 的补齐写入不得遗留旧建筑成员。"
	)
	enemy.objective_target = plant
	enemy.configure_multiplayer_proxy()
	_expect(
		enemy.objective_target == null
		and index.get_targeting_enemy_count(plant) == 0,
		"多人代理清空 objective_target 时必须同步释放反向成员。"
	)
	enemy.objective_target = plant
	_expect(index.get_targeting_enemy_count(plant) == 1, "脱树前必须恢复目标成员。")

	var escaping_enemy := BASIC_ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(escaping_enemy != null, "Home escape 测试必须能实例化正式敌人场景。")
	if escaping_enemy != null:
		escaping_enemy.set_physics_process(false)
		root.add_child(escaping_enemy)
		escaping_enemy.setup(BASIC_ENEMY_CONFIG, null, null, null)
		index.track(escaping_enemy)
		escaping_enemy.objective_target = plant
		_expect(index.get_targeting_enemy_count(plant) == 2, "逃逸前必须登记第二个成员。")
		_expect(escaping_enemy.remove_for_home_escape(), "存活敌人必须能进入 Home escape。")
		_expect(
			escaping_enemy.objective_target == null
			and index.get_targeting_enemy_count(plant) == 1,
			"Home escape 必须在 queue_free 前同步释放建筑目标。"
		)
	enemy.queue_free()
	await process_frame
	_expect(
		index.get_tracked_enemy_count() == 0
		and index.get_plant_membership_count() == 0
		and index.get_targeting_enemy_count(plant) == 0,
		"敌人 tree_exited 必须 O(1) 释放跟踪、反向关系和 plant 桶。"
	)
	index.clear()
	player_probe.free()
	plant.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
