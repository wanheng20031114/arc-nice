extends SceneTree

const WOOD: PickupConfig = preload(
	"res://resources/config/materials/material_wood.tres"
)
const HEALTH_POTION: PickupConfig = preload(
	"res://resources/config/consumables/healing_potion.tres"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_unstarted_store_remains_unstarted()
	_test_validation_is_read_only()
	call_deferred("_finish")


func _test_unstarted_store_remains_unstarted() -> void:
	var store := RunStateStore.new()
	root.add_child(store)
	var signal_counts := _connect_economy_signal_counts(store)
	_expect(not store.run_started, "测试前 RunState 不应自行开始 Run。")
	_expect(
		not store.validate_party_economy_snapshot({}),
		"未开始 Run 时只读校验必须拒绝输入。"
	)
	_expect(not store.run_started, "只读校验不得隐式创建 Run。")
	_expect(
		_all_signal_counts_are_zero(signal_counts),
		"未开始 Run 的只读校验不得发出任何经济信号。"
	)
	store.queue_free()


func _test_validation_is_read_only() -> void:
	var store := RunStateStore.new()
	root.add_child(store)
	store.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	_expect(store.try_add_item_count(WOOD, 3), "测试必须建立非零本地背包 revision。")
	_expect(store.register_multiplayer_peer_state(1), "远端账本必须先显式注册。")
	_expect(
		store.try_add_item_count_for_peer(1, HEALTH_POTION, 2),
		"测试必须建立非零远端背包 revision。"
	)
	_expect(store.set_party_xirang_balance(0, 321), "本地息壤必须可初始化。")
	_expect(store.set_party_xirang_balance(1, 654), "远端息壤必须可初始化。")

	var peer_ids := PackedInt32Array([0, 1])
	var valid_snapshot := store.export_party_economy_snapshot(peer_ids)
	var baseline_snapshot := valid_snapshot.duplicate(true)
	var baseline_revisions := _capture_revisions(store)
	var signal_counts := _connect_economy_signal_counts(store)

	_expect(
		store.validate_party_economy_snapshot(valid_snapshot),
		"当前完整经济快照必须通过只读校验。"
	)
	_expect(
		_state_is_unchanged(
			store,
			peer_ids,
			baseline_snapshot,
			baseline_revisions,
			signal_counts
		),
		"成功校验不得改写背包、账本、revision 或发信号。"
	)

	var invalid_snapshot := valid_snapshot.duplicate(true)
	(invalid_snapshot["inventories"] as Array)[0]["slots"][0][
		"stack_count"
	] = PickupConfig.get_inventory_stack_limit(WOOD) + 1
	_expect(
		not store.validate_party_economy_snapshot(invalid_snapshot),
		"超出资源堆叠上限的背包槽必须校验失败。"
	)
	_expect(
		_state_is_unchanged(
			store,
			peer_ids,
			baseline_snapshot,
			baseline_revisions,
			signal_counts
		),
		"失败校验同样不得产生部分写入或信号。"
	)

	var rewind_snapshot := valid_snapshot.duplicate(true)
	var local_inventory := (rewind_snapshot["inventories"] as Array)[0] as Dictionary
	local_inventory["revision"] = int(local_inventory["revision"]) - 1
	for raw_slot in local_inventory["slots"] as Array:
		(raw_slot as Dictionary)["revision"] = local_inventory["revision"]
	_expect(
		not store.validate_party_economy_snapshot(rewind_snapshot),
		"默认校验必须拒绝低于当前基线的背包 revision。"
	)
	_expect(
		store.validate_party_economy_snapshot(rewind_snapshot, true),
		"明确允许 rewind 时应按正式快照应用规则通过完整解码。"
	)
	_expect(
		_state_is_unchanged(
			store,
			peer_ids,
			baseline_snapshot,
			baseline_revisions,
			signal_counts
		),
		"允许 rewind 的校验也必须保持完全只读。"
	)
	store.queue_free()


func _connect_economy_signal_counts(store: RunStateStore) -> Dictionary:
	var counts := {
		"inventory": 0,
		"warehouse": 0,
		"xirang": 0,
		"light_stone": 0,
		"status": 0,
	}
	store.inventory_changed.connect(func() -> void:
		counts["inventory"] = int(counts["inventory"]) + 1
	)
	store.shared_warehouse_ledger_changed.connect(func(_snapshot: Dictionary) -> void:
		counts["warehouse"] = int(counts["warehouse"]) + 1
	)
	store.party_xirang_ledger_changed.connect(func(_snapshot: Dictionary) -> void:
		counts["xirang"] = int(counts["xirang"]) + 1
	)
	store.party_light_stone_ledger_changed.connect(func(_snapshot: Dictionary) -> void:
		counts["light_stone"] = int(counts["light_stone"]) + 1
	)
	store.party_status_ledger_changed.connect(func(_snapshot: Dictionary) -> void:
		counts["status"] = int(counts["status"]) + 1
	)
	return counts


func _capture_revisions(store: RunStateStore) -> Dictionary:
	return {
		"local_inventory": store.get_inventory_revision(),
		"peer_inventory": store.get_inventory_revision_for_peer(1),
		"warehouse": store.get_shared_warehouse_ledger_revision(),
		"xirang": store.get_party_xirang_ledger_revision(),
		"light_stone": store.get_party_light_stone_ledger_revision(),
		"status": store.get_party_status_ledger_revision(),
	}


func _state_is_unchanged(
	store: RunStateStore,
	peer_ids: PackedInt32Array,
	baseline_snapshot: Dictionary,
	baseline_revisions: Dictionary,
	signal_counts: Dictionary
) -> bool:
	return (
		store.export_party_economy_snapshot(peer_ids) == baseline_snapshot
		and _capture_revisions(store) == baseline_revisions
		and _all_signal_counts_are_zero(signal_counts)
	)


func _all_signal_counts_are_zero(signal_counts: Dictionary) -> bool:
	for count in signal_counts.values():
		if int(count) != 0:
			return false
	return true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("RUN_STATE_PARTY_ECONOMY_VALIDATION_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
