extends SceneTree

const LEDGER_SOURCE_PATH := "res://scene/combat/runtime/wave_enemy_terminal_ledger.gd"
const LARGE_HISTORY_RECORD_COUNT := 5916
const LARGE_HISTORY_ATTACHED_COUNT := 300
const COUNT_BENCHMARK_ITERATIONS := 10000
const COUNT_BENCHMARK_BUDGET_MSEC := 250.0

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_objective_lifecycle_and_aggregate()
	_test_auxiliary_lifecycle()
	_test_reserved_spawn_binding()
	_test_terminal_batch_removal_preserves_detach_identity()
	_test_role_lifecycle_indexes_are_atomic_and_defensive()
	_test_reset_snapshot_and_clear_entity_boundaries()
	_test_large_history_count_complexity_contract()
	_test_single_wire_terminal_composition()
	if failures.is_empty():
		print("WAVE_ENEMY_TERMINAL_LEDGER_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_objective_lifecycle_and_aggregate() -> void:
	var ledger := WaveEnemyTerminalLedger.new()
	_expect(ledger.reset(3), "账本必须接受空的三目标波次。")
	_expect(
		ledger.register_enemy(101, WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE),
		"首个 objective 必须完成 ACTIVE 登记。"
	)
	_expect(
		ledger.resolve_enemy(101, CombatTypes.EnemyTerminalReason.DEFEATED),
		"ACTIVE objective 必须能原子结算为 DEFEATED。"
	)
	_expect(
		not ledger.resolve_enemy(101, CombatTypes.EnemyTerminalReason.DEFEATED),
		"重复 defeated 信号不得重复增加聚合。"
	)
	_expect(
		ledger.get_defeated() == 1
		and ledger.get_resolved() == 1
		and ledger.get_attached_enemy_count() == 1,
		"TERMINAL 实体离树前仍须占用 attached 容量。"
	)
	var defeated_detach := ledger.detach_enemy(101)
	_expect(
		defeated_detach.accepted
		and not defeated_detach.terminal_created
		and defeated_detach.terminal_reason
		== CombatTypes.EnemyTerminalReason.DEFEATED,
		"defeat→exit 必须保留原终结原因且不产生第二终结。"
	)

	_expect(
		ledger.register_enemy(102, WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE)
		and ledger.resolve_enemy(102, CombatTypes.EnemyTerminalReason.ESCAPED),
		"第二个 objective 必须能结算为 ESCAPED。"
	)
	var escaped_detach := ledger.detach_enemy(102)
	_expect(
		escaped_detach.accepted
		and not escaped_detach.terminal_created
		and escaped_detach.terminal_reason
		== CombatTypes.EnemyTerminalReason.ESCAPED,
		"escape→exit 必须保留唯一 ESCAPED 终结。"
	)

	_expect(
		ledger.register_enemy(103, WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE),
		"第三个 objective 必须完成登记。"
	)
	var removed_detach := ledger.detach_enemy(103)
	_expect(
		removed_detach.accepted
		and removed_detach.terminal_created
		and removed_detach.terminal_reason
		== CombatTypes.EnemyTerminalReason.REMOVED,
		"未终结 objective 离树必须原子补记 REMOVED。"
	)
	_expect(
		ledger.get_removed() == 1
		and ledger.get_resolved() == 3
		and ledger.is_complete(),
		"REMOVED 必须推进 resolved 并允许波次完成。"
	)
	var duplicate_detach := ledger.detach_enemy(103)
	_expect(
		duplicate_detach.known and not duplicate_detach.accepted,
		"重复 tree_exited 必须是已知且幂等的空操作。"
	)


func _test_auxiliary_lifecycle() -> void:
	var ledger := WaveEnemyTerminalLedger.new()
	ledger.reset(1)
	_expect(
		ledger.register_enemy(201, WaveEnemyTerminalLedger.EnemyRole.AUXILIARY),
		"Boss auxiliary 必须显式登记。"
	)
	_expect(
		ledger.resolve_enemy(201, CombatTypes.EnemyTerminalReason.DEFEATED),
		"auxiliary 仍须拥有唯一实体终结。"
	)
	_expect(
		ledger.get_spawned() == 0
		and ledger.get_resolved() == 0
		and not ledger.is_complete(),
		"auxiliary 不得污染 objective 波次聚合。"
	)
	_expect(
		ledger.detach_enemy(201).accepted,
		"已终结 auxiliary 必须能进入 DETACHED。"
	)


func _test_reserved_spawn_binding() -> void:
	var ledger := WaveEnemyTerminalLedger.new()
	_expect(ledger.reset(2, 2), "Boss/远端快照必须能预留 spawned 槽位。")
	_expect(
		ledger.register_enemy(301, WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE)
		and ledger.register_enemy(302, WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE)
		and ledger.get_spawned() == 2,
		"实体登记必须绑定预留槽位而非重复增加 spawned。"
	)
	_expect(
		not ledger.register_enemy(303, WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE),
		"objective 登记不得超过 total。"
	)
	_expect(
		ledger.reset(10, 10, 6, 1, 1),
		"账本必须接受含八个已终结目标的完整快照。"
	)
	_expect(
		ledger.register_enemy(311, WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE)
		and ledger.register_enemy(312, WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE)
		and not ledger.register_enemy(
			313, WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE
		),
		"快照后只能绑定 spawned-resolved 个未终结实体槽位。"
	)


func _test_terminal_batch_removal_preserves_detach_identity() -> void:
	var ledger := WaveEnemyTerminalLedger.new()
	ledger.reset(2)
	ledger.register_enemy(321, WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE)
	ledger.register_enemy(322, WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE)
	ledger.register_enemy(323, WaveEnemyTerminalLedger.EnemyRole.AUXILIARY)
	ledger.resolve_enemy(321, CombatTypes.EnemyTerminalReason.DEFEATED)
	_expect(
		ledger.resolve_all_active_as_removed() == 2
		and ledger.get_defeated() == 1
		and ledger.get_removed() == 1
		and ledger.get_resolved() == 2,
		"终局批处理必须保留既有原因，并将剩余 ACTIVE 静默收束为 REMOVED。"
	)
	for enemy_id in [321, 322, 323]:
		var detach := ledger.detach_enemy(enemy_id)
		_expect(
			detach.known and detach.accepted and not detach.terminal_created,
			"终局批处理后的 tree_exited 必须只完成 DETACHED，不得再创建终结。"
		)
	_expect(
		ledger.get_attached_enemy_count() == 0,
		"终局实体全部离树后必须保留已知的 DETACHED 身份。"
	)
	_expect_lifecycle_counts(ledger, 0, 0, 0, 0, 0, 0, "终局批处理完成")


func _test_role_lifecycle_indexes_are_atomic_and_defensive() -> void:
	var ledger := WaveEnemyTerminalLedger.new()
	ledger.reset(2)
	_expect(
		ledger.register_enemy(501, WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE)
		and ledger.register_enemy(
			502, WaveEnemyTerminalLedger.EnemyRole.AUXILIARY
		),
		"objective 与 auxiliary 必须能同时登记到独立生命周期索引。"
	)
	_expect_lifecycle_counts(ledger, 2, 1, 1, 2, 1, 1, "混合角色登记")
	_expect(
		ledger.get_active_enemy_ids().has(501)
		and ledger.get_active_enemy_ids().has(502)
		and ledger.get_attached_enemy_ids(
			WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE
		).has(501)
		and not ledger.get_attached_enemy_ids(
			WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE
		).has(502),
		"生命周期 ID 视图必须严格遵守角色过滤。"
	)

	var exposed_active_ids := ledger.get_active_enemy_ids()
	exposed_active_ids.clear()
	var exposed_attached_ids := ledger.get_attached_enemy_ids(
		WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE
	)
	exposed_attached_ids[999] = true
	_expect_lifecycle_counts(
		ledger, 2, 1, 1, 2, 1, 1, "调用方修改返回的 Dictionary"
	)
	_expect(
		ledger.get_active_enemy_ids().size() == 2
		and not ledger.get_attached_enemy_ids().has(999),
		"账本不得把内部生命周期索引直接暴露给调用方。"
	)

	_expect(
		not ledger.register_enemy(
			501, WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE
		),
		"重复登记必须被拒绝。"
	)
	_expect_lifecycle_counts(ledger, 2, 1, 1, 2, 1, 1, "重复登记被拒绝")

	_expect(
		ledger.resolve_enemy(501, CombatTypes.EnemyTerminalReason.DEFEATED),
		"ACTIVE objective 必须能进入 TERMINAL。"
	)
	_expect_lifecycle_counts(
		ledger, 1, 0, 1, 2, 1, 1, "objective 终结但仍附着"
	)
	_expect(
		not ledger.resolve_enemy(501, CombatTypes.EnemyTerminalReason.REMOVED),
		"重复终结不得改写原因或再次修改生命周期索引。"
	)
	_expect_lifecycle_counts(ledger, 1, 0, 1, 2, 1, 1, "重复终结被拒绝")

	var objective_detach := ledger.detach_enemy(501)
	_expect(
		objective_detach.accepted and not objective_detach.terminal_created,
		"TERMINAL objective 首次离树必须只退出 ATTACHED 索引。"
	)
	_expect_lifecycle_counts(ledger, 1, 0, 1, 1, 0, 1, "objective 离树")
	var duplicate_detach := ledger.detach_enemy(501)
	_expect(
		duplicate_detach.known and not duplicate_detach.accepted,
		"重复离树必须保持幂等。"
	)
	_expect_lifecycle_counts(ledger, 1, 0, 1, 1, 0, 1, "重复离树被拒绝")

	var active_auxiliary_detach := ledger.detach_enemy(502)
	_expect(
		active_auxiliary_detach.accepted
		and active_auxiliary_detach.terminal_created
		and ledger.get_defeated() == 1
		and ledger.get_removed() == 0,
		"ACTIVE auxiliary 离树必须完成实体终结，但不得污染 objective 聚合。"
	)
	_expect_lifecycle_counts(ledger, 0, 0, 0, 0, 0, 0, "auxiliary 直接离树")
	_expect(
		ledger.get_active_enemy_count(99) == 0
		and ledger.get_attached_enemy_count(99) == 0
		and ledger.get_active_enemy_ids(99).is_empty()
		and ledger.get_attached_enemy_ids(99).is_empty(),
		"未知角色过滤必须返回空视图，不得退化为全量查询。"
	)


func _test_reset_snapshot_and_clear_entity_boundaries() -> void:
	var ledger := WaveEnemyTerminalLedger.new()
	ledger.reset(3)
	ledger.register_enemy(601, WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE)
	ledger.register_enemy(602, WaveEnemyTerminalLedger.EnemyRole.AUXILIARY)
	ledger.resolve_enemy(601, CombatTypes.EnemyTerminalReason.DEFEATED)
	_expect_lifecycle_counts(ledger, 1, 0, 1, 2, 1, 1, "非法 reset 前")
	_expect(
		not ledger.reset(-1),
		"非法 reset 必须在修改聚合或生命周期索引前被拒绝。"
	)
	_expect_lifecycle_counts(ledger, 1, 0, 1, 2, 1, 1, "非法 reset 后")
	_expect(ledger.has_enemy(601) and ledger.get_defeated() == 1, "非法 reset 不得破坏历史状态。")

	_expect(
		ledger.apply_snapshot(10, 10, 6, 1, 1),
		"完整快照必须能开启一套无本地实体的新生命周期索引。"
	)
	_expect_lifecycle_counts(ledger, 0, 0, 0, 0, 0, 0, "apply_snapshot 后")
	_expect(
		not ledger.has_enemy(601)
		and ledger.get_snapshot()
		== {
			"total": 10,
			"spawned": 10,
			"defeated": 6,
			"escaped": 1,
			"removed": 1,
			"resolved": 8,
		},
		"apply_snapshot 必须清除旧波实体身份并完整保留远端聚合。"
	)
	ledger.register_enemy(611, WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE)
	ledger.register_enemy(612, WaveEnemyTerminalLedger.EnemyRole.AUXILIARY)
	ledger.resolve_enemy(611, CombatTypes.EnemyTerminalReason.DEFEATED)
	var aggregate_before_clear := ledger.get_snapshot()
	ledger.clear_entities()
	_expect_lifecycle_counts(ledger, 0, 0, 0, 0, 0, 0, "clear_entities 后")
	_expect(
		ledger.get_snapshot() == aggregate_before_clear
		and not ledger.has_enemy(611)
		and not ledger.has_enemy(612),
		"clear_entities 必须只清实体历史与索引，不能改写快照聚合。"
	)

	_expect(ledger.reset(1), "新波 reset 必须重新建立空账本。")
	_expect(
		ledger.register_enemy(601, WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE),
		"新波必须允许复用旧波实体 ID。"
	)
	_expect_lifecycle_counts(ledger, 1, 1, 0, 1, 1, 0, "新波实体登记")


func _test_large_history_count_complexity_contract() -> void:
	var ledger := WaveEnemyTerminalLedger.new()
	ledger.reset(LARGE_HISTORY_RECORD_COUNT)
	var detached_count := (
		LARGE_HISTORY_RECORD_COUNT - LARGE_HISTORY_ATTACHED_COUNT
	)
	for enemy_id in range(1, LARGE_HISTORY_RECORD_COUNT + 1):
		_expect(
			ledger.register_enemy(
				enemy_id, WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE
			),
			"大历史账本必须登记第 %d 个 objective。" % enemy_id
		)
		if enemy_id <= detached_count:
			ledger.resolve_enemy(
				enemy_id, CombatTypes.EnemyTerminalReason.REMOVED
			)
			ledger.detach_enemy(enemy_id)
	_expect_lifecycle_counts(
		ledger,
		LARGE_HISTORY_ATTACHED_COUNT,
		LARGE_HISTORY_ATTACHED_COUNT,
		0,
		LARGE_HISTORY_ATTACHED_COUNT,
		LARGE_HISTORY_ATTACHED_COUNT,
		0,
		"5916 历史 / 300 attached"
	)
	_expect(
		ledger.has_enemy(1)
		and not ledger.is_enemy_attached(1)
		and ledger.has_enemy(LARGE_HISTORY_RECORD_COUNT),
		"复杂度场景必须真实保留 5916 条身份历史，而非删除 DETACHED 记录。"
	)

	var count_checksum := 0
	var benchmark_started_usec := Time.get_ticks_usec()
	for _iteration in range(COUNT_BENCHMARK_ITERATIONS):
		count_checksum += ledger.get_attached_enemy_count()
		count_checksum += ledger.get_active_enemy_count(
			WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE
		)
	var elapsed_msec := (
		float(Time.get_ticks_usec() - benchmark_started_usec) / 1000.0
	)
	print(
		"WAVE_LEDGER_COUNT_BENCH history=%d attached=%d calls=%d elapsed_ms=%.3f"
		% [
			LARGE_HISTORY_RECORD_COUNT,
			LARGE_HISTORY_ATTACHED_COUNT,
			COUNT_BENCHMARK_ITERATIONS * 2,
			elapsed_msec,
		]
	)
	_expect(
		count_checksum
		== LARGE_HISTORY_ATTACHED_COUNT * COUNT_BENCHMARK_ITERATIONS * 2,
		"O(1) 计数压力循环必须始终返回 300 个热实体。"
	)
	_expect(
		elapsed_msec <= COUNT_BENCHMARK_BUDGET_MSEC,
		"5916 条历史下 20000 次 O(1) 计数超过 %.1f ms 预算（实际 %.3f ms）。"
		% [COUNT_BENCHMARK_BUDGET_MSEC, elapsed_msec]
	)
	_assert_count_source_contract()


func _test_single_wire_terminal_composition() -> void:
	var ledger := WaveEnemyTerminalLedger.new()
	ledger.reset(3)
	var mp_enemy := MpEnemyCoordinator.new()
	_expect(
		_simulate_wire_lifecycle(
			ledger,
			mp_enemy,
			401,
			CombatTypes.EnemyTerminalReason.DEFEATED
		) == 1,
		"defeat→exit 在 wire 上只能产生一个终结。"
	)
	_expect(
		_simulate_wire_lifecycle(
			ledger,
			mp_enemy,
			402,
			CombatTypes.EnemyTerminalReason.ESCAPED
		) == 1,
		"escape→exit 在 wire 上只能产生一个终结。"
	)
	_expect(
		_simulate_wire_lifecycle(ledger, mp_enemy, 403, -1) == 1,
		"unexpected exit 在 wire 上必须产生唯一 REMOVED。"
	)
	_expect(
		_simulate_wire_lifecycle(
			ledger,
			mp_enemy,
			404,
			CombatTypes.EnemyTerminalReason.DEFEATED,
			WaveEnemyTerminalLedger.EnemyRole.AUXILIARY
		) == 1,
		"已 defeated Boss add 被清场时不得产生第二个 wire 终结。"
	)
	_expect(
		_simulate_wire_lifecycle(
			ledger,
			mp_enemy,
			405,
			CombatTypes.EnemyTerminalReason.ESCAPED,
			WaveEnemyTerminalLedger.EnemyRole.AUXILIARY
		) == 1,
		"已 escaped Boss add 被清场时不得产生第二个 wire 终结。"
	)
	mp_enemy.free()


func _assert_count_source_contract() -> void:
	var source := FileAccess.get_file_as_string(LEDGER_SOURCE_PATH)
	_expect(not source.is_empty(), "必须能读取账本源码以验证 O(1) 计数契约。")
	for method_name in [
		"get_active_enemy_count",
		"get_attached_enemy_count",
		"_get_role_index_count",
	]:
		var method_source := _extract_function_source(source, method_name)
		_expect(
			not method_source.is_empty()
			and not method_source.contains("_records")
			and not method_source.contains("\n\tfor "),
			"%s 不得访问或遍历历史记录。" % method_name
		)
	var role_count_source := _extract_function_source(
		source, "_get_role_index_count"
	)
	_expect(
		role_count_source.contains(".size()"),
		"角色计数必须直接读取稀疏索引 size，而不是重建临时集合。"
	)


func _extract_function_source(source: String, method_name: String) -> String:
	var method_start := source.find("func %s(" % method_name)
	if method_start < 0:
		return ""
	var next_method_start := source.find("\nfunc ", method_start + 1)
	if next_method_start < 0:
		return source.substr(method_start)
	return source.substr(method_start, next_method_start - method_start)


func _expect_lifecycle_counts(
	ledger: WaveEnemyTerminalLedger,
	active_total: int,
	active_objective: int,
	active_auxiliary: int,
	attached_total: int,
	attached_objective: int,
	attached_auxiliary: int,
	context: String
) -> void:
	var actual := [
		ledger.get_active_enemy_count(),
		ledger.get_active_enemy_count(
			WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE
		),
		ledger.get_active_enemy_count(
			WaveEnemyTerminalLedger.EnemyRole.AUXILIARY
		),
		ledger.get_attached_enemy_count(),
		ledger.get_attached_enemy_count(
			WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE
		),
		ledger.get_attached_enemy_count(
			WaveEnemyTerminalLedger.EnemyRole.AUXILIARY
		),
	]
	var expected := [
		active_total,
		active_objective,
		active_auxiliary,
		attached_total,
		attached_objective,
		attached_auxiliary,
	]
	_expect(
		actual == expected,
		"%s 生命周期索引计数错误：expected=%s actual=%s"
		% [context, expected, actual]
	)


func _simulate_wire_lifecycle(
	ledger: WaveEnemyTerminalLedger,
	mp_enemy: MpEnemyCoordinator,
	enemy_id: int,
	reason: int,
	role: WaveEnemyTerminalLedger.EnemyRole = (
		WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE
	)
) -> int:
	ledger.register_enemy(enemy_id, role)
	var wire_count := 0
	if reason >= 0:
		ledger.resolve_enemy(enemy_id, reason as CombatTypes.EnemyTerminalReason)
		if not mp_enemy.build_host_terminal_event(
			enemy_id, reason, Vector2.ZERO
		).is_empty():
			wire_count += 1
	var detach := ledger.detach_enemy(enemy_id)
	if (
		detach.accepted
		and (
			detach.terminal_created
			or detach.terminal_reason
			== CombatTypes.EnemyTerminalReason.DEFEATED
		)
		and not mp_enemy.build_host_terminal_event(
			enemy_id,
			CombatTypes.EnemyTerminalReason.REMOVED,
			Vector2.ZERO
		).is_empty()
	):
		wire_count += 1
	return wire_count


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
