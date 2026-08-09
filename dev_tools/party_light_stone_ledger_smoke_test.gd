extends SceneTree

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var store := RunStateStore.new()
	root.add_child(store)
	store.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	var signal_snapshots: Array[Dictionary] = []
	store.party_light_stone_ledger_changed.connect(
		func(snapshot: Dictionary) -> void:
			signal_snapshots.append(snapshot)
	)

	var initial := store.export_party_light_stone_ledger()
	_expect(
		store.get_party_light_stone_amount() == 0
		and store.get_party_light_stone_ledger_revision() == 0
		and int(initial.get("schema_version", 0))
		== RunStateStore.PARTY_LIGHT_STONE_LEDGER_SCHEMA_VERSION,
		"新局必须从0块共享光石和revision 0开始。"
	)
	_expect(
		store.set_party_light_stone_amount(3)
		and store.get_party_light_stone_amount() == 3
		and store.get_party_light_stone_ledger_revision() == 1
		and signal_snapshots.size() == 1,
		"权威设置共享光石必须推进一次revision并发布一次完整账本。"
	)
	var before_rejections := store.export_party_light_stone_ledger()
	_expect(
		not store.try_change_party_light_stone_amount(-1, 0)
		and not store.try_change_party_light_stone_amount(-4, 1)
		and store.export_party_light_stone_ledger() == before_rejections
		and signal_snapshots.size() == 1,
		"陈旧revision和余额不足的光石扣除必须零副作用拒绝。"
	)
	_expect(
		store.try_change_party_light_stone_amount(-1, 1)
		and store.get_party_light_stone_amount() == 2
		and store.get_party_light_stone_ledger_revision() == 2
		and signal_snapshots.size() == 2,
		"合法光石消费必须按CAS精确扣除并推进一次revision。"
	)

	var party_snapshot := store.export_party_economy_snapshot(
		PackedInt32Array([0])
	)
	_expect(
		int(party_snapshot.get("schema_version", 0))
		== RunStateStore.PARTY_ECONOMY_SCHEMA_VERSION
		and party_snapshot.has("light_stone_ledger"),
		"Party economy schema 4必须携带共享光石账本。"
	)
	var next_light_stone := (
		party_snapshot["light_stone_ledger"] as Dictionary
	).duplicate(true)
	next_light_stone["revision"] = int(next_light_stone["revision"]) + 1
	next_light_stone["amount"] = 5
	var next_xirang := (
		party_snapshot["xirang_ledger"] as Dictionary
	).duplicate(true)
	next_xirang["revision"] = int(next_xirang["revision"]) + 1
	(next_xirang["values"] as Dictionary)["0"] = 1000
	var expected_inventory_revisions := {
		0: store.get_inventory_revision(),
	}
	var warehouse_revision := store.get_shared_warehouse_ledger_revision()
	var xirang_revision := store.get_party_xirang_ledger_revision()
	var status_revision := store.get_party_status_ledger_revision()
	_expect(
		store.apply_authoritative_party_transaction(
			party_snapshot,
			warehouse_revision,
			expected_inventory_revisions,
			xirang_revision,
			next_xirang,
			status_revision,
			{},
			2,
			next_light_stone
		)
		and store.get_party_light_stone_amount() == 5
		and store.get_party_light_stone_ledger_revision() == 3
		and store.get_party_xirang_balance(0) == 1000
		and store.get_party_xirang_ledger_revision() == xirang_revision + 1
		and signal_snapshots.size() == 3,
		"经济CAS必须把光石消费与息壤奖励作为一个准备后提交的事务发布。"
	)
	var committed := store.export_party_economy_snapshot(PackedInt32Array([0]))
	_expect(
		not store.apply_authoritative_party_transaction(
			party_snapshot,
			warehouse_revision,
			expected_inventory_revisions,
			xirang_revision,
			next_xirang,
			status_revision,
			{},
			2,
			next_light_stone
		)
		and store.export_party_economy_snapshot(PackedInt32Array([0]))
		== committed,
		"重复提交旧光石revision必须完整拒绝且不得改写其他账本。"
	)

	var mirror := RunStateStore.new()
	root.add_child(mirror)
	mirror.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	_expect(
		mirror.apply_party_economy_snapshot(committed, true)
		and mirror.get_party_light_stone_amount() == 5
		and mirror.get_party_light_stone_ledger_revision() == 3
		and mirror.get_party_xirang_balance(0) == 1000,
		"重连经济快照必须恢复共享光石绝对值与revision。"
	)
	mirror.queue_free()
	store.queue_free()
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PARTY_LIGHT_STONE_LEDGER_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
