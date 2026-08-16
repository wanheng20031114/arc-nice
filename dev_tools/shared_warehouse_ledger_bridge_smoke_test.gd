extends SceneTree

const WAREHOUSE_SCRIPT := preload(
	"res://scene/plant_defense/oak_warehouse.gd"
)
const BRIDGE := preload(
	"res://scene/game_modes/tower_defense/economy/warehouse/shared_warehouse_ledger_bridge.gd"
)
const PLANK := preload("res://resources/config/materials/material_plank.tres")
const BASKETBALL := preload(
	"res://resources/config/collectibles/collectible_basketball.tres"
)
const WAREHOUSE_NET_ID := 7301

var _failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	run_state.register_multiplayer_peer_state(1)
	var fixture := Node2D.new()
	fixture.name = "SharedWarehouseLedgerBridgeSmokeTest"
	root.add_child(fixture)

	var battle_warehouse := _make_warehouse()
	_expect(
		BRIDGE.bind_identity(
			battle_warehouse,
			WAREHOUSE_NET_ID
		),
		"真实仓库实体应能绑定跨场景稳定ID。"
	)
	_expect(
		battle_warehouse.try_add_storage_item_count(PLANK, 10),
		"战斗仓库应能存入10块木板。"
	)
	_expect(
		BRIDGE.persist_to_ledger(
			run_state,
			battle_warehouse,
			WAREHOUSE_NET_ID
		),
		"离开战斗前应能把真实仓库捕获到RunState账本。"
	)

	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var purchase := economy.resolve_chicken_bro(
		RogueEncounterEconomyCoordinator.OPTION_PURCHASE,
		730173,
		[1],
		"warehouse-roundtrip"
	)
	_expect(
		bool(purchase.get("reward_granted", false))
		and int(purchase.get("warehouse_paid", -1)) == 10
		and run_state.get_shared_warehouse_item_total(PLANK) == 0
		and run_state.get_party_item_total(BASKETBALL, PackedInt32Array([1])) == 1,
		"路线遭遇应从持久仓库扣除10块木板并只发一个篮球。"
	)

	var returned_warehouse := _make_warehouse()
	_expect(
		BRIDGE.restore_from_ledger(
			run_state,
			returned_warehouse,
			WAREHOUSE_NET_ID
		),
		"返回战斗时同ID真实仓库应恢复路线扣款后的快照。"
	)
	_expect(
		returned_warehouse.get_storage_item_total(PLANK) == 0
		and returned_warehouse.get_storage_revision() == 2,
		"返回战斗的仓库必须看到0块木板与扣款后的revision。"
	)
	_expect(
		returned_warehouse.try_add_storage_item_count(PLANK, 3)
		and BRIDGE.persist_to_ledger(
			run_state,
			returned_warehouse,
			WAREHOUSE_NET_ID
		),
		"返回战斗后的仓库变更应继续写回同一账本记录。"
	)
	var second_return := _make_warehouse()
	_expect(
		BRIDGE.restore_from_ledger(
			run_state,
			second_return,
			WAREHOUSE_NET_ID
		)
		and second_return.get_storage_item_total(PLANK) == 3,
		"重复跨场景往返不得丢失返回战斗后的仓库变更。"
	)

	economy.free()
	battle_warehouse.free()
	returned_warehouse.free()
	second_return.free()
	fixture.queue_free()
	for _frame in 3:
		await process_frame
	run_state.begin_new_run(&"weishidaier", false)
	if _failures.is_empty():
		print("SHARED_WAREHOUSE_LEDGER_BRIDGE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _make_warehouse() -> OakWarehouse:
	var warehouse := WAREHOUSE_SCRIPT.new() as OakWarehouse
	warehouse.storage_items.resize(OakWarehouse.STORAGE_CAPACITY)
	warehouse.storage_stack_counts.resize(OakWarehouse.STORAGE_CAPACITY)
	warehouse.storage_stack_counts.fill(0)
	warehouse.multiplayer_storage_request_timer = Timer.new()
	warehouse.add_child(warehouse.multiplayer_storage_request_timer)
	return warehouse


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
