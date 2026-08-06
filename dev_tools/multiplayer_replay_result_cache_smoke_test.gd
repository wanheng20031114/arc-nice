extends SceneTree

const CACHE_SCRIPT := preload(
	"res://scene/multiplayer/peer_replay_result_cache.gd"
)
const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")

const PRESSURE_CAPACITY := 256
const PRESSURE_INSERT_COUNT := 20_000
const BENCHMARK_ROUNDS := 5

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_result_copy_and_peer_isolation()
	_test_stable_fifo_replacement_and_cleanup()
	_test_mp_game_cache_capacities_and_lifecycle()
	_test_pressure_ab_and_source_contract()
	if failures.is_empty():
		print("MULTIPLAYER_REPLAY_RESULT_CACHE_SMOKE_TEST: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	print("MULTIPLAYER_REPLAY_RESULT_CACHE_SMOKE_TEST: FAIL (%d)" % failures.size())
	quit(1)


func _test_result_copy_and_peer_isolation() -> void:
	var cache := CACHE_SCRIPT.new(3)
	var original := {
		"request_id": 1,
		"nested": {"revision": 7},
	}
	cache.store_result(2, 1, original)
	cache.store_result(3, 1, {"request_id": 1, "peer_marker": 3})
	(original["nested"] as Dictionary)["revision"] = 99
	var first_read := cache.get_result(2, 1) as Dictionary
	_expect(
		int((first_read.get("nested", {}) as Dictionary).get("revision", -1)) == 7,
		"缓存写入必须深拷贝结果，调用方后续修改不能污染幂等重放。"
	)
	(first_read["nested"] as Dictionary)["revision"] = 123
	var second_read := cache.get_result(2, 1) as Dictionary
	_expect(
		int((second_read.get("nested", {}) as Dictionary).get("revision", -1)) == 7,
		"缓存读取必须深拷贝结果，发送方修改副本不能反向污染缓存。"
	)
	_expect(
		int((cache.get_result(3, 1) as Dictionary).get("peer_marker", 0)) == 3,
		"相同请求键必须按 peer 隔离。"
	)


func _test_stable_fifo_replacement_and_cleanup() -> void:
	var cache := CACHE_SCRIPT.new(3)
	var exposed_results: Dictionary = cache.results_by_peer
	cache.store_result(2, 1, {"version": 1})
	cache.store_result(2, 2, {"version": 2})
	cache.store_result(2, 3, {"version": 3})
	cache.store_result(2, 1, {"version": 11})
	cache.store_result(2, 4, {"version": 4})
	_expect(
		(cache.get_result(2, 1) as Dictionary).is_empty()
		and int((cache.get_result(2, 2) as Dictionary).get("version", 0)) == 2
		and int((cache.get_result(2, 4) as Dictionary).get("version", 0)) == 4,
		"同键替换必须保留原 FIFO 位置；超限后应淘汰最早首次插入的键。"
	)
	cache.store_result(3, 9, {"peer_marker": 3})
	cache.clear_peer(2)
	_expect(
		not exposed_results.has(2)
		and exposed_results.has(3)
		and cache.get_peer_count() == 1,
		"断线清理必须只释放目标 peer 的载荷和环形索引。"
	)
	cache.clear()
	_expect(
		is_same(exposed_results, cache.results_by_peer)
		and exposed_results.is_empty()
		and cache.get_peer_count() == 0,
		"会话清理必须原地清空公开诊断字典及全部环形顺序元数据。"
	)


func _test_mp_game_cache_capacities_and_lifecycle() -> void:
	var mp_game := MP_GAME_SCRIPT.new()
	var transactions := MpTransactionsCoordinator.new()
	transactions.name = "TransactionsCoordinator"
	mp_game.add_child(transactions)
	mp_game.transactions_coordinator = transactions
	var session := MpSessionCoordinator.new()
	mp_game.add_child(session)
	mp_game.session_coordinator = session
	var players := MpPlayerCoordinator.new()
	mp_game.add_child(players)
	mp_game.player_coordinator = players
	var enemies := MpEnemyCoordinator.new()
	mp_game.add_child(enemies)
	mp_game.enemy_coordinator = enemies
	var projectiles := MpProjectileCoordinator.new()
	mp_game.add_child(projectiles)
	mp_game.projectile_coordinator = projectiles
	for request_id in range(1, 258):
		mp_game.call(
			"_cache_warehouse_transaction_result",
			2,
			7001,
			request_id,
			{"request_id": request_id, "kind": "warehouse"}
		)
		mp_game.call(
			"_cache_production_command_result",
			2,
			7002,
			request_id,
			{"request_id": request_id, "kind": "production"}
		)
	for request_id in range(1, 34):
		transactions.cache_simple_crafting_result(
			2,
			request_id,
			{"request_id": request_id, "kind": "crafting"}
		)
	var warehouse_results := mp_game.get(
		"_warehouse_transaction_results_by_peer"
	) as Dictionary
	var production_results := mp_game.get(
		"_production_command_results_by_peer"
	) as Dictionary
	var crafting_results := transactions.get(
		"_simple_crafting_results_by_peer"
	) as Dictionary
	_expect(
		(warehouse_results.get(2, {}) as Dictionary).size() == 256
		and (production_results.get(2, {}) as Dictionary).size() == 256
		and (crafting_results.get(2, {}) as Dictionary).size() == 32,
		"三类 MpGame 重放缓存必须分别保持 256/256/32 的按 peer 硬上限。"
	)
	_expect(
		(mp_game.call(
			"_get_cached_warehouse_transaction_result", 2, 7001, 1
		) as Dictionary).is_empty()
		and not (mp_game.call(
			"_get_cached_warehouse_transaction_result", 2, 7001, 257
		) as Dictionary).is_empty()
		and (mp_game.call(
			"_get_cached_production_command_result", 2, 7002, 1
		) as Dictionary).is_empty()
		and not (mp_game.call(
			"_get_cached_production_command_result", 2, 7002, 257
		) as Dictionary).is_empty()
		and transactions.get_cached_simple_crafting_result(2, 1).is_empty()
		and not transactions.get_cached_simple_crafting_result(2, 33).is_empty(),
		"容量环绕后必须只淘汰每类缓存最老结果并保留最新结果。"
	)
	for peer_id in [2, 3]:
		mp_game.call(
			"_cache_warehouse_transaction_result",
			peer_id,
			8001,
			900,
			{"peer_id": peer_id}
		)
		mp_game.call(
			"_cache_production_command_result",
			peer_id,
			8002,
			900,
			{"peer_id": peer_id}
		)
		transactions.cache_simple_crafting_result(
			peer_id,
			900,
			{"peer_id": peer_id}
		)
	mp_game.call("_clear_peer_network_state", 2)
	_expect(
		not warehouse_results.has(2)
		and not production_results.has(2)
		and not crafting_results.has(2)
		and warehouse_results.has(3)
		and production_results.has(3)
		and crafting_results.has(3),
		"MpGame 断线生命周期必须同步清理三类目标 peer 缓存且不影响其他 peer。"
	)
	mp_game.call("_exit_tree")
	_expect(
		warehouse_results.is_empty()
		and production_results.is_empty()
		and crafting_results.is_empty(),
		"MpGame 场景退出必须同步清空三类载荷和环形顺序元数据。"
	)
	mp_game.free()


func _test_pressure_ab_and_source_contract() -> void:
	# Warm both implementations before timing parser/JIT-independent container work.
	_run_legacy_pressure(1_000)
	_run_ring_pressure(1_000)
	var legacy_samples: Array[int] = []
	var ring_samples: Array[int] = []
	var legacy_key_slots := 0
	for round_index in range(BENCHMARK_ROUNDS):
		if round_index % 2 == 0:
			var legacy_result := _run_legacy_pressure(PRESSURE_INSERT_COUNT)
			legacy_samples.append(int(legacy_result["usec"]))
			legacy_key_slots = int(legacy_result["key_slots"])
			ring_samples.append(int(_run_ring_pressure(PRESSURE_INSERT_COUNT)))
		else:
			ring_samples.append(int(_run_ring_pressure(PRESSURE_INSERT_COUNT)))
			var legacy_result := _run_legacy_pressure(PRESSURE_INSERT_COUNT)
			legacy_samples.append(int(legacy_result["usec"]))
			legacy_key_slots = int(legacy_result["key_slots"])
	var legacy_median := _median_usec(legacy_samples)
	var ring_median := _median_usec(ring_samples)
	print(
		(
			"MULTIPLAYER_REPLAY_CACHE_AB inserts=%d capacity=%d "
			+ "legacy_median_usec=%d ring_median_usec=%d speedup=%.2fx "
			+ "legacy_key_slots=%d ring_eviction_arrays=0"
		) % [
			PRESSURE_INSERT_COUNT,
			PRESSURE_CAPACITY,
			legacy_median,
			ring_median,
			float(legacy_median) / maxf(float(ring_median), 1.0),
			legacy_key_slots,
		]
	)
	_expect(
		legacy_key_slots
		== (
			(PRESSURE_INSERT_COUNT - PRESSURE_CAPACITY)
			* (PRESSURE_CAPACITY + 1)
		),
		"旧 keys()[0] 淘汰基线必须如实记录每次超限分配的完整键数组工作量。"
	)
	_expect(
		ring_median < legacy_median,
		"固定环形 FIFO 的 20k 压测中位耗时必须优于 keys()[0] 基线。"
	)
	var cache_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/peer_replay_result_cache.gd"
	)
	var mp_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/mp_game.gd"
	)
	_expect(
		not cache_source.contains(".keys()")
		and not cache_source.contains("pop_front")
		and not cache_source.contains("remove_at")
		and not mp_source.contains("peer_cache.keys()[0]"),
		"生产重放缓存不得退化为 keys 数组、头删或线性位移淘汰。"
	)


func _run_legacy_pressure(insert_count: int) -> Dictionary:
	var cache: Dictionary = {}
	var allocated_key_slots := 0
	var started_usec := Time.get_ticks_usec()
	for request_id in range(insert_count):
		cache[request_id] = {"request_id": request_id}
		if cache.size() > PRESSURE_CAPACITY:
			var keys := cache.keys()
			allocated_key_slots += keys.size()
			cache.erase(keys[0])
	return {
		"usec": Time.get_ticks_usec() - started_usec,
		"key_slots": allocated_key_slots,
		"retained": cache.size(),
	}


func _run_ring_pressure(insert_count: int) -> int:
	var cache := CACHE_SCRIPT.new(PRESSURE_CAPACITY)
	var started_usec := Time.get_ticks_usec()
	for request_id in range(insert_count):
		cache.store_result(2, request_id, {"request_id": request_id})
	var elapsed_usec := Time.get_ticks_usec() - started_usec
	_expect(
		cache.get_peer_entry_count(2) == mini(insert_count, PRESSURE_CAPACITY),
		"环形压测缓存必须始终服从固定容量。"
	)
	return elapsed_usec


func _median_usec(samples: Array[int]) -> int:
	var sorted_samples := samples.duplicate()
	sorted_samples.sort()
	return sorted_samples[sorted_samples.size() / 2]


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
