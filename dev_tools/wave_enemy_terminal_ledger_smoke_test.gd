extends SceneTree

var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_objective_lifecycle_and_aggregate()
	_test_auxiliary_lifecycle()
	_test_reserved_spawn_binding()
	_test_terminal_batch_removal_preserves_detach_identity()
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
