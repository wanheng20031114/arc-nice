extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const WOOD := preload("res://resources/config/materials/material_wood.tres")
const HEALTH_PICKUP := preload("res://resources/config/pickups/pickup_health.tres")
const APPLE := preload("res://resources/config/collectibles/collectible_apple.tres")
const XIAOCONG_FATE_STONE := preload(
	"res://resources/config/pickups/xiaocong_fate_stone.tres"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier")
	_test_local_revision_and_snapshot(run_state)
	_test_peer_slot_state_and_snapshot(run_state)
	_test_collectible_effect_cap_does_not_limit_carrying(run_state)
	await _test_stacked_item_use(run_state)
	_test_inventory_locked_fate_stone(run_state)
	_test_starting_inventory_opt_out(run_state)
	run_state.begin_new_run(&"weishidaier")

	if failures.is_empty():
		print("RUN_STATE_INVENTORY_REVISION_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_local_revision_and_snapshot(run_state: RunStateStore) -> void:
	_expect(run_state.get_inventory_revision() == 0, "新局本地背包revision必须从0开始。")
	_expect(
		run_state.get_item(0) == WOOD and run_state.get_item_count(0) == 5,
		"新局本地背包必须自带5份木头。"
	)
	_expect(run_state.try_add_item_count(WOOD, 3), "本地背包必须能加入3份木材。")
	_expect(run_state.get_inventory_revision() == 1, "一次本地加入必须只递增一次revision。")
	var snapshot := run_state.export_inventory_snapshot()
	_expect(run_state.discard_item(0), "本地测试堆叠必须能整槽丢弃。")
	_expect(run_state.get_inventory_revision() == 2, "整槽丢弃必须递增一次revision。")
	_expect(not run_state.apply_inventory_snapshot(snapshot), "旧revision完整快照不得覆盖新状态。")

	var repaired_snapshot := snapshot.duplicate(true)
	repaired_snapshot["revision"] = 3
	_expect(run_state.apply_inventory_snapshot(repaired_snapshot), "更新revision的权威快照必须可以恢复本地背包。")
	_expect(
		run_state.get_item_count(0) == 8 and run_state.get_inventory_revision() == 3,
		"完整快照恢复后物品数量与revision必须精确一致。"
	)


func _test_peer_slot_state_and_snapshot(run_state: RunStateStore) -> void:
	const PEER_ID := 3
	run_state.ensure_multiplayer_peer_state(PEER_ID)
	_expect(
		run_state.get_item_for_peer(PEER_ID, 0) == WOOD
		and run_state.get_item_count_for_peer(PEER_ID, 0) == 5
		and run_state.get_inventory_revision_for_peer(PEER_ID) == 0,
		"每个新建Peer背包必须自带5份木头且revision保持为0。"
	)
	run_state.ensure_multiplayer_peer_state(PEER_ID)
	_expect(
		run_state.get_item_count_for_peer(PEER_ID, 0) == 5,
		"重复确保同一Peer状态时不得再次发放初始木头。"
	)
	_expect(run_state.try_add_item_count_for_peer(PEER_ID, WOOD, 5), "Peer背包必须能加入堆叠物资。")
	var initial_state := run_state.get_inventory_slot_state_for_peer(PEER_ID, 0)
	_expect(
		initial_state.get("config_path", "") == WOOD.resource_path
		and int(initial_state.get("stack_count", 0)) == 10
		and int(initial_state.get("revision", 0)) == 1,
		"精确槽状态必须包含路径、数量和peer revision。"
	)
	var initial_snapshot := run_state.export_inventory_snapshot_for_peer(PEER_ID)
	_expect(run_state.discard_item_for_peer(PEER_ID, 0), "Peer堆叠必须能整槽移除。")
	_expect(
		not run_state.apply_inventory_snapshot_for_peer(PEER_ID, initial_snapshot),
		"Peer旧快照不得回滚较新的背包状态。"
	)
	_expect(
		not run_state.apply_inventory_snapshot_for_peer(PEER_ID, initial_snapshot, true),
		"即使Host明确标记强制修复，旧revision也不得越过跨信道栅栏回退新状态。"
	)
	_expect(
		run_state.get_item_count_for_peer(PEER_ID, 0) == 0
		and run_state.get_inventory_revision_for_peer(PEER_ID) == 2,
		"迟到的强制修复不得抹掉较新的Peer物品状态或降低revision。"
	)

	var repaired_state := initial_state.duplicate(true)
	repaired_state["stack_count"] = 4
	repaired_state["revision"] = 3
	_expect(
		run_state.apply_inventory_slot_state_for_peer(PEER_ID, repaired_state),
		"连续revision的精确槽状态必须可应用。"
	)
	_expect(
		run_state.apply_inventory_slot_state_for_peer(PEER_ID, repaired_state),
		"重复收到完全相同的精确槽状态必须幂等成功。"
	)
	var skipped_state := repaired_state.duplicate(true)
	skipped_state["revision"] = 5
	_expect(
		not run_state.apply_inventory_slot_state_for_peer(PEER_ID, skipped_state),
		"跳过revision的单槽状态必须拒绝并等待完整快照。"
	)


func _test_stacked_item_use(run_state: RunStateStore) -> void:
	const PEER_ID := 4
	var fixture := Node.new()
	root.add_child(fixture)
	var player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(player)
	player.set_physics_process(false)
	await process_frame
	var stacked_health := HEALTH_PICKUP.duplicate() as PickupConfig
	stacked_health.stackable = true
	stacked_health.inventory_stack_limit = 10
	player.current_health = maxi(player.max_health - 20, 1)
	_expect(
		run_state.try_add_item_count_for_peer(PEER_ID, stacked_health, 3),
		"测试用可堆叠消耗品必须能加入Peer背包。"
	)
	var before_use_revision := run_state.get_inventory_revision_for_peer(PEER_ID)
	_expect(run_state.try_use_item_for_peer(PEER_ID, 1, player), "Host必须能使用Peer的可堆叠消耗品。")
	_expect(
		run_state.get_item_count_for_peer(PEER_ID, 1) == 2,
		"成功使用一份堆叠物品后必须保留同槽剩余2份，而不是清空整槽。"
	)
	_expect(
		run_state.get_inventory_revision_for_peer(PEER_ID) == before_use_revision + 1,
		"使用一份堆叠物品必须只递增一次Peer背包revision。"
	)
	fixture.queue_free()
	await process_frame


func _test_collectible_effect_cap_does_not_limit_carrying(run_state: RunStateStore) -> void:
	const PEER_ID := 5
	_expect(
		run_state.try_add_item_count_for_peer(PEER_ID, APPLE, APPLE.collectible_max_copies),
		"Host必须允许收藏品达到配置的效果生效份数上限。"
	)
	_expect(
		run_state.can_add_item_count_for_peer(PEER_ID, APPLE, 1)
		and run_state.try_add_item_count_for_peer(PEER_ID, APPLE, 1),
		"收藏品效果封顶后，Host仍必须允许Peer携带第6份。"
	)
	_expect(
		run_state.get_item_for_peer(PEER_ID, APPLE.collectible_max_copies + 1) == APPLE,
		"第6份苹果必须真实写入新的Peer背包槽，而不是被效果上限吞掉。"
	)


func _test_inventory_locked_fate_stone(run_state: RunStateStore) -> void:
	run_state.begin_new_run(&"weishidaier", false)
	_expect(run_state.try_add_item(XIAOCONG_FATE_STONE), "命运石必须能写入空背包。")
	var local_revision := run_state.get_inventory_revision()
	_expect(
		not run_state.try_use_item(0, null)
		and not run_state.discard_item(0)
		and not run_state.move_item_stack_to_slot(0, 1)
		and not bool(
			run_state.take_item_stack_if_revision(0, local_revision).get("success", false)
		),
		"本地命运石必须拒绝使用、删除、移动与事务取出。"
	)
	_expect(
		run_state.get_item(0) == XIAOCONG_FATE_STONE
		and run_state.get_inventory_revision() == local_revision,
		"被拒绝的命运石操作不得改变物品或背包revision。"
	)

	const PEER_ID := 7
	run_state.ensure_multiplayer_peer_state(PEER_ID)
	_expect(
		run_state.try_add_item_for_peer(PEER_ID, XIAOCONG_FATE_STONE),
		"Host必须能把命运石写入Peer背包。"
	)
	var peer_revision := run_state.get_inventory_revision_for_peer(PEER_ID)
	_expect(
		not run_state.discard_item_for_peer(PEER_ID, 0)
		and not run_state.move_item_stack_to_slot_for_peer_if_revision(
			PEER_ID,
			0,
			1,
			peer_revision
		)
		and not bool(
			run_state.take_item_stack_for_peer_if_revision(
				PEER_ID,
				0,
				peer_revision
			).get("success", false)
		),
		"Peer命运石必须拒绝删除、移动与Host事务取出。"
	)
	_expect(
		run_state.get_item_for_peer(PEER_ID, 0) == XIAOCONG_FATE_STONE
		and run_state.get_inventory_revision_for_peer(PEER_ID) == peer_revision,
		"被拒绝的Peer命运石操作不得改变物品或revision。"
	)


func _test_starting_inventory_opt_out(run_state: RunStateStore) -> void:
	const PEER_ID := 6
	run_state.begin_new_run(&"weishidaier", false)
	_expect(
		run_state.get_item(0) == null and run_state.get_inventory_revision() == 0,
		"隔离测试必须能显式创建无初始物资且revision为0的本地背包。"
	)
	run_state.ensure_multiplayer_peer_state(PEER_ID)
	_expect(
		run_state.get_item_for_peer(PEER_ID, 0) == null
		and run_state.get_inventory_revision_for_peer(PEER_ID) == 0,
		"无初始物资策略必须同步应用于之后创建的Peer背包。"
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
