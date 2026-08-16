extends SceneTree

const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")
const PEER_LEDGER_SCRIPT := preload(
	"res://scene/multiplayer/peer_ledger/mp_peer_ledger_coordinator.gd"
)
const NET_CONSTANTS := preload("res://scene/multiplayer/net_constants.gd")
const WOOD := preload(
	"res://resources/config/materials/material_wood.tres"
)
const WATER_BOTTLE := preload(
	"res://resources/config/materials/material_water_bottle.tres"
)
const STONE_MILL_ITEM := preload(
	"res://resources/config/buildings/building_stone_mill.tres"
)
const WOOD_STATION_ITEM := preload(
	"res://resources/config/buildings/building_wood_processing_station.tres"
)
const WOODEN_CORE := preload(
	"res://resources/config/materials/material_wooden_core.tres"
)
const PLANK := preload(
	"res://resources/config/materials/material_plank.tres"
)
const BAMBOO_MORTAR_ITEM := preload(
	"res://resources/config/buildings/building_bamboo_mortar.tres"
)

const REMOTE_PEER_ID := 2

var failures: Array[String] = []


class HostNetManagerStub:
	extends NetManagerStore

	func is_host() -> bool:
		return true

	func is_client() -> bool:
		return false

	func get_local_peer_id() -> int:
		return 1

	func is_gameplay_ingress_admitted(peer_id: int) -> bool:
		return peer_id > 0

	func get_session_participant_incarnation(peer_id: int) -> int:
		return peer_id if peer_id > 0 else 0

	func resolve_session_participant_peer_id(participant_incarnation: int) -> int:
		return participant_incarnation if participant_incarnation > 0 else 0


class ClientNetManagerStub:
	extends NetManagerStore

	func is_host() -> bool:
		return false

	func is_client() -> bool:
		return true

	func get_local_peer_id() -> int:
		return 2

	func is_gameplay_ingress_admitted(peer_id: int) -> bool:
		return peer_id > 0

	func get_session_participant_incarnation(peer_id: int) -> int:
		return peer_id if peer_id > 0 else 0

	func resolve_session_participant_peer_id(participant_incarnation: int) -> int:
		return participant_incarnation if participant_incarnation > 0 else 0


class CapturingMpGame:
	extends "res://scene/multiplayer/mp_game.gd"

	var simple_crafting_results: Array[Dictionary] = []

	func _ready() -> void:
		pass

	func _exit_tree() -> void:
		pass

	func capture_simple_crafting_result(
		peer_id: int,
		request_id: int,
		recipe_id: String,
		result_code: String,
		inventory_snapshot: Dictionary,
		force_inventory_repair: bool
	) -> void:
		simple_crafting_results.append({
			"peer_id": peer_id,
			"request_id": request_id,
			"recipe_id": recipe_id,
			"result": result_code,
			"inventory_snapshot": inventory_snapshot.duplicate(true),
			"force_inventory_repair": force_inventory_repair,
		})


class TestTowerRuntime:
	extends TowerDefenseGame

	var shown_crafting_results: Array[Dictionary] = []

	func _ready() -> void:
		pass

	func _physics_process(_delta: float) -> void:
		pass

	func get_player_for_peer(peer_id: int) -> Player:
		return peer_players.get(peer_id) as Player

	func show_simple_crafting_result(
		recipe_id: StringName,
		result: StringName,
		request_token: int
	) -> void:
		shown_crafting_results.append({
			"recipe_id": recipe_id,
			"result": result,
			"request_token": request_token,
		})


class TestTowerModeAdapter:
	extends TowerDefenseMultiplayerModeAdapter

	## 宽夹具只装配本用例需要的塔防端口，避免伪造整棵正式场景依赖树。
	func bind_research_fixture(coordinator: ResearchCoordinator) -> void:
		_research_coordinator = coordinator

	func show_simple_crafting_result(
		recipe_id: StringName,
		result: StringName,
		request_token: int
	) -> void:
		var runtime := get_tower_runtime() as TestTowerRuntime
		if runtime != null:
			runtime.show_simple_crafting_result(recipe_id, result, request_token)


class RejectingStonePlantSystem:
	extends PlantSystem

	const TEST_CONFIG := preload(
		"res://resources/config/plant_defense/stone_mill.tres"
	)

	var validation_calls := 0
	var stone_config_validation_calls := 0

	func get_config(plant_id: StringName) -> PlantDefenseConfig:
		return TEST_CONFIG if plant_id == &"stone_mill" else null

	func is_placement_valid_for_player(
		_top_left_cell: Vector2i,
		config: PlantDefenseConfig,
		_placement_player: Player
	) -> bool:
		validation_calls += 1
		if config == TEST_CONFIG:
			stone_config_validation_calls += 1
		return false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(
		NET_CONSTANTS.PROTOCOL_VERSION == 79,
		"多人协议v79必须保留内容摘要、同局成员身份、P1D/P1E 与既有 wire 合同。"
	)
	var authoritative_snapshot := _test_host_authoritative_crafting()
	_test_host_research_gated_crafting()
	_test_inventory_building_placement_authenticity(authoritative_snapshot)
	_test_client_rejects_bad_authoritative_snapshot(authoritative_snapshot)

	if failures.is_empty():
		print("STONE_MILL_MULTIPLAYER_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_host_authoritative_crafting() -> Dictionary:
	var run_state := RunStateStore.new()
	run_state.begin_new_run(&"weishidaier", false)
	run_state.register_multiplayer_peer_state(REMOTE_PEER_ID)
	_expect(
		run_state.try_add_item_count_for_peer(REMOTE_PEER_ID, WOOD, 10)
		and run_state.try_add_item_count_for_peer(
			REMOTE_PEER_ID,
			WATER_BOTTLE,
			10
		),
		"Host石磨台制造夹具必须能为远端Peer准备10木头和10水瓶。"
	)

	var player := Player.new()
	var runtime := TestTowerRuntime.new()
	var tower_adapter := _bind_tower_multiplayer_mode_adapter(runtime)
	runtime.peer_players = {REMOTE_PEER_ID: player}
	var net_manager := HostNetManagerStub.new()
	var mp_game := CapturingMpGame.new()
	mp_game.net_manager = net_manager
	mp_game.run_state = run_state
	mp_game.game = runtime
	mp_game._mode_adapter = tower_adapter
	mp_game.tower_mode_adapter = tower_adapter
	tower_adapter.attach_multiplayer_session(mp_game)
	var transactions := _bind_transactions_coordinator(
		mp_game,
		runtime,
		tower_adapter,
		net_manager,
		run_state
	)

	var crafting_revision := run_state.get_inventory_revision_for_peer(
		REMOTE_PEER_ID
	)
	transactions.apply_authoritative_simple_crafting_request(
		REMOTE_PEER_ID,
		41,
		String(SimpleCraftingRegistry.STONE_MILL_ID),
		crafting_revision
	)
	var committed_revision := run_state.get_inventory_revision_for_peer(
		REMOTE_PEER_ID
	)
	var success_result := _result_at(mp_game.simple_crafting_results, 0)
	var authoritative_snapshot := (
		success_result.get("inventory_snapshot", {}) as Dictionary
	).duplicate(true)
	_expect(
		str(success_result.get("recipe_id", "")) == "stone_mill"
		and str(success_result.get("result", ""))
		== String(RunStateStore.CRAFT_RESULT_SUCCESS)
		and committed_revision == crafting_revision + 1
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			WOOD
		) == 0
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			WATER_BOTTLE
		) == 0
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			STONE_MILL_ITEM
		) == 1,
		"Host必须按请求Peer原子扣除10木头和10水瓶，只产出1个石磨台并推进一次revision。"
	)
	_expect(
		_snapshot_contains_exact_item_path(
			authoritative_snapshot,
			STONE_MILL_ITEM.resource_path,
			1
		),
		"Host制造结果快照必须携带石磨台建筑物品的规范资源路径。"
	)

	transactions.apply_authoritative_simple_crafting_request(
		REMOTE_PEER_ID,
		41,
		String(SimpleCraftingRegistry.STONE_MILL_ID),
		crafting_revision
	)
	var replay_result := _result_at(mp_game.simple_crafting_results, 1)
	_expect(
		run_state.get_inventory_revision_for_peer(REMOTE_PEER_ID)
		== committed_revision
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			STONE_MILL_ITEM
		) == 1
		and str(replay_result.get("result", ""))
		== String(RunStateStore.CRAFT_RESULT_SUCCESS)
		and int((replay_result.get(
			"inventory_snapshot",
			{}
		) as Dictionary).get("revision", -1)) == committed_revision,
		"重复request_id必须只重放当前Host快照，不能重复扣料、产出或推进revision。"
	)

	transactions.apply_authoritative_simple_crafting_request(
		REMOTE_PEER_ID,
		42,
		String(SimpleCraftingRegistry.STONE_MILL_ID),
		crafting_revision
	)
	var stale_result := _result_at(mp_game.simple_crafting_results, 2)
	_expect(
		str(stale_result.get("result", ""))
		== String(RunStateStore.CRAFT_RESULT_STALE_REVISION)
		and bool(stale_result.get("force_inventory_repair", false))
		and run_state.get_inventory_revision_for_peer(REMOTE_PEER_ID)
		== committed_revision,
		"新的请求携带过期背包revision时，Host必须拒绝并要求权威快照修复。"
	)

	transactions.apply_authoritative_simple_crafting_request(
		REMOTE_PEER_ID,
		43,
		"res://resources/config/production/simple_stone_mill.tres",
		committed_revision
	)
	var forged_result := _result_at(mp_game.simple_crafting_results, 3)
	_expect(
		str(forged_result.get("recipe_id", "")) == ""
		and str(forged_result.get("result", ""))
		== String(RunStateStore.CRAFT_RESULT_INVALID_RECIPE)
		and run_state.get_inventory_revision_for_peer(REMOTE_PEER_ID)
		== committed_revision,
		"Host必须只接受简易制造注册表中的wire id，不能把资源路径当作石磨台配方。"
	)

	var round_trip_state := RunStateStore.new()
	round_trip_state.begin_new_run(&"weishidaier", false)
	round_trip_state.register_multiplayer_peer_state(REMOTE_PEER_ID)
	_expect(
		round_trip_state.apply_inventory_snapshot_for_peer(
			REMOTE_PEER_ID,
			authoritative_snapshot
		)
		and round_trip_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			STONE_MILL_ITEM
		) == 1,
		"同版本客户端必须能从Host快照按规范资源路径还原石磨台建筑物品。"
	)

	mp_game.free()
	net_manager.free()
	runtime.free()
	player.free()
	round_trip_state.free()
	run_state.free()
	return authoritative_snapshot


func _test_host_research_gated_crafting() -> void:
	var run_state := RunStateStore.new()
	run_state.begin_new_run(&"weishidaier", false)
	run_state.register_multiplayer_peer_state(REMOTE_PEER_ID)
	_expect(
		run_state.try_add_item_count_for_peer(
			REMOTE_PEER_ID,
			WOODEN_CORE,
			1
		)
		and run_state.try_add_item_count_for_peer(
			REMOTE_PEER_ID,
			PLANK,
			10
		),
		"科研门槛夹具必须能为远端Peer准备迫击炮配方材料。"
	)

	var player := Player.new()
	var research_coordinator := ResearchCoordinator.new()
	var runtime := TestTowerRuntime.new()
	runtime.research_coordinator = research_coordinator
	var tower_adapter := _bind_tower_multiplayer_mode_adapter(
		runtime,
		research_coordinator
	)
	runtime.peer_players = {REMOTE_PEER_ID: player}
	var net_manager := HostNetManagerStub.new()
	var mp_game := CapturingMpGame.new()
	mp_game.net_manager = net_manager
	mp_game.run_state = run_state
	mp_game.game = runtime
	mp_game._mode_adapter = tower_adapter
	mp_game.tower_mode_adapter = tower_adapter
	tower_adapter.attach_multiplayer_session(mp_game)
	var transactions := _bind_transactions_coordinator(
		mp_game,
		runtime,
		tower_adapter,
		net_manager,
		run_state
	)

	var locked_revision := run_state.get_inventory_revision_for_peer(
		REMOTE_PEER_ID
	)
	transactions.apply_authoritative_simple_crafting_request(
		REMOTE_PEER_ID,
		51,
		String(SimpleCraftingRegistry.BAMBOO_MORTAR_ID),
		locked_revision
	)
	var locked_result := _result_at(mp_game.simple_crafting_results, 0)
	_expect(
		str(locked_result.get("result", ""))
		== String(RunStateStore.CRAFT_RESULT_RESEARCH_LOCKED)
		and run_state.get_inventory_revision_for_peer(REMOTE_PEER_ID)
		== locked_revision
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			WOODEN_CORE
		) == 1
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			PLANK
		) == 10
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			BAMBOO_MORTAR_ITEM
		) == 0,
		"Host必须拒绝未完成全局科研的迫击炮配方，且不能扣料、产出或推进revision。"
	)

	research_coordinator.global_research_states[
		GlobalResearchRegistry.BAMBOO_MORTAR_CRAFTING_ID
	] = ResearchCoordinator.GlobalResearchState.COMPLETED
	research_coordinator.global_research_elapsed[
		GlobalResearchRegistry.BAMBOO_MORTAR_CRAFTING_ID
	] = 30.0
	transactions.apply_authoritative_simple_crafting_request(
		REMOTE_PEER_ID,
		52,
		String(SimpleCraftingRegistry.BAMBOO_MORTAR_ID),
		locked_revision
	)
	var success_result := _result_at(mp_game.simple_crafting_results, 1)
	var committed_revision := run_state.get_inventory_revision_for_peer(
		REMOTE_PEER_ID
	)
	_expect(
		str(success_result.get("result", ""))
		== String(RunStateStore.CRAFT_RESULT_SUCCESS)
		and committed_revision == locked_revision + 1
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			WOODEN_CORE
		) == 0
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			PLANK
		) == 0
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			BAMBOO_MORTAR_ITEM
		) == 1,
		"科研完成后Host必须为所有Peer解锁迫击炮简易制作并原子结算配方。"
	)

	transactions.apply_authoritative_simple_crafting_request(
		REMOTE_PEER_ID,
		52,
		String(SimpleCraftingRegistry.BAMBOO_MORTAR_ID),
		locked_revision
	)
	var replay_result := _result_at(mp_game.simple_crafting_results, 2)
	_expect(
		str(replay_result.get("result", ""))
		== String(RunStateStore.CRAFT_RESULT_SUCCESS)
		and run_state.get_inventory_revision_for_peer(REMOTE_PEER_ID)
		== committed_revision
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			BAMBOO_MORTAR_ITEM
		) == 1,
		"科研解锁后的重复request_id只能重放结果，不能重复制造。"
	)

	mp_game.free()
	net_manager.free()
	runtime.free()
	research_coordinator.free()
	player.free()
	run_state.free()


func _test_inventory_building_placement_authenticity(
	authoritative_snapshot: Dictionary
) -> void:
	var run_state := RunStateStore.new()
	run_state.begin_new_run(&"weishidaier", false)
	run_state.register_multiplayer_peer_state(REMOTE_PEER_ID)
	_expect(
		run_state.apply_inventory_snapshot_for_peer(
			REMOTE_PEER_ID,
			authoritative_snapshot
		),
		"建筑物品防伪用例必须先还原Host石磨台快照。"
	)
	var stone_mill_slot := _find_peer_item_slot(
		run_state,
		REMOTE_PEER_ID,
		STONE_MILL_ITEM
	)
	var player := Player.new()
	var plant_system := RejectingStonePlantSystem.new()
	var runtime := TestTowerRuntime.new()
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	runtime.run_state = run_state
	runtime.plant_system = plant_system
	runtime.peer_players = {REMOTE_PEER_ID: player}
	var plant_runtime := TowerDefensePlantRuntimeCoordinator.new()
	plant_runtime.name = "PlantRuntimeCoordinator"
	runtime.add_child(plant_runtime)
	runtime.plant_runtime_coordinator = plant_runtime
	plant_runtime.setup(runtime.runtime_mode, null, null, plant_system, null)
	var rejections: Array[StringName] = []
	plant_runtime.plant_placement_rejected.connect(
		func(
			_request_id: int,
			_requester_peer_id: int,
			reason: StringName
		) -> void:
			rejections.append(reason)
	)
	var initial_revision := run_state.get_inventory_revision_for_peer(
		REMOTE_PEER_ID
	)

	plant_runtime.request_multiplayer_inventory_placement(
		REMOTE_PEER_ID,
		501,
		&"stone_mill",
		Vector2i(3, 4),
		stone_mill_slot,
		initial_revision,
		WOOD_STATION_ITEM.resource_path,
		run_state,
		player,
		false
	)
	_expect(
		rejections == [&"invalid_inventory_item"]
		and plant_system.validation_calls == 0
		and run_state.get_inventory_revision_for_peer(REMOTE_PEER_ID)
		== initial_revision
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			STONE_MILL_ITEM
		) == 1,
		"伪造其他建筑资源路径时，Host必须在位置校验和扣物品前拒绝请求。"
	)

	rejections.clear()
	plant_runtime.request_multiplayer_inventory_placement(
		REMOTE_PEER_ID,
		502,
		&"wood_processing_station",
		Vector2i(3, 4),
		stone_mill_slot,
		initial_revision,
		STONE_MILL_ITEM.resource_path,
		run_state,
		player,
		false
	)
	_expect(
		rejections == [&"invalid_inventory_item"]
		and plant_system.validation_calls == 0
		and run_state.get_inventory_revision_for_peer(REMOTE_PEER_ID)
		== initial_revision,
		"伪造plant_id时，Host必须要求背包物品的placeable_plant_id与请求完全一致。"
	)

	rejections.clear()
	plant_runtime.request_multiplayer_inventory_placement(
		REMOTE_PEER_ID,
		503,
		&"stone_mill",
		Vector2i(3, 4),
		stone_mill_slot,
		initial_revision,
		STONE_MILL_ITEM.resource_path,
		run_state,
		player,
		false
	)
	_expect(
		rejections == [&"invalid_position"]
		and plant_system.validation_calls == 1
		and plant_system.stone_config_validation_calls == 1
		and run_state.get_inventory_revision_for_peer(REMOTE_PEER_ID)
		== initial_revision
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			STONE_MILL_ITEM
		) == 1,
		"规范石磨台路径和plant_id必须通过物品防伪校验，再由Host权威位置规则决定是否落地。"
	)

	runtime.free()
	plant_system.free()
	player.free()
	run_state.free()


func _bind_tower_multiplayer_mode_adapter(
	runtime: TowerDefenseGame,
	research_coordinator: ResearchCoordinator = null
) -> TestTowerModeAdapter:
	var adapter := TestTowerModeAdapter.new()
	adapter.name = "MultiplayerModeAdapter"
	runtime.add_child(adapter)
	adapter.bind_runtime(runtime)
	if research_coordinator != null:
		adapter.bind_research_fixture(research_coordinator)
	runtime.multiplayer_mode_adapter = adapter
	runtime.tower_multiplayer_mode_adapter = adapter
	return adapter


func _bind_transactions_coordinator(
	mp_game: CapturingMpGame,
	runtime: CombatRuntimeBase,
	mode_adapter: MultiplayerModeAdapter,
	net_manager: NetManagerStore,
	run_state: RunStateStore
) -> MpTransactionsCoordinator:
	var transactions := MpTransactionsCoordinator.new()
	transactions.name = "TransactionsCoordinator"
	mp_game.add_child(transactions)
	mp_game.transactions_coordinator = transactions
	transactions.bind_session(
		mp_game,
		runtime,
		mode_adapter,
		net_manager,
		run_state,
		{}
	)
	net_manager.loading_session_id = 1
	var peer_ledger := PEER_LEDGER_SCRIPT.new()
	peer_ledger.name = "PeerLedgerCoordinator"
	mp_game.add_child(peer_ledger)
	mp_game.peer_ledger_coordinator = peer_ledger
	var peer_ledger_role := (
		PEER_LEDGER_SCRIPT.RuntimeRole.HOST
		if net_manager.is_host()
		else PEER_LEDGER_SCRIPT.RuntimeRole.CLIENT
	)
	mp_game._peer_ledger_generation = peer_ledger.bind_session(
		mp_game,
		peer_ledger_role,
		net_manager.get_game_session_incarnation(),
		run_state.has_multiplayer_peer_state,
		Callable(mp_game, "_is_peer_result_envelope_ready"),
		Callable(mp_game, "_commit_pending_peer_ledger_envelope")
	)
	transactions.simple_crafting_result_broadcast_requested.connect(
		mp_game.capture_simple_crafting_result
	)
	return transactions


func _test_client_rejects_bad_authoritative_snapshot(
	authoritative_snapshot: Dictionary
) -> void:
	var run_state := RunStateStore.new()
	run_state.begin_new_run(&"weishidaier", false)
	run_state.register_multiplayer_peer_state(REMOTE_PEER_ID)
	var player := Player.new()
	var runtime := TestTowerRuntime.new()
	var tower_adapter := _bind_tower_multiplayer_mode_adapter(runtime)
	runtime.peer_players = {REMOTE_PEER_ID: player}
	var net_manager := ClientNetManagerStub.new()
	_configure_active_session_member_fixture(net_manager, REMOTE_PEER_ID)
	_expect(
		net_manager.is_session_member_active(REMOTE_PEER_ID),
		"客户端制作结果夹具必须先建立活跃会话成员，才能立即提交 CH6 结果。"
	)
	var mp_game := CapturingMpGame.new()
	mp_game.net_manager = net_manager
	mp_game.run_state = run_state
	mp_game.game = runtime
	mp_game._mode_adapter = tower_adapter
	mp_game.tower_mode_adapter = tower_adapter
	tower_adapter.attach_multiplayer_session(mp_game)
	var transactions := _bind_transactions_coordinator(
		mp_game,
		runtime,
		tower_adapter,
		net_manager,
		run_state
	)
	transactions.track_local_simple_crafting_request(77, 9001)

	var bad_snapshot := authoritative_snapshot.duplicate(true)
	var bad_slots := bad_snapshot.get("slots", []) as Array
	var stone_mill_slot := _find_snapshot_item_slot(
		bad_snapshot,
		STONE_MILL_ITEM.resource_path
	)
	if stone_mill_slot >= 0:
		var bad_slot := bad_slots[stone_mill_slot] as Dictionary
		bad_slot["stack_count"] = 2
	mp_game.net_simple_crafting_result(
		REMOTE_PEER_ID,
		77,
		"stone_mill",
		String(RunStateStore.CRAFT_RESULT_SUCCESS),
		bad_snapshot,
		false,
		net_manager.get_session_participant_incarnation(REMOTE_PEER_ID),
		net_manager.get_game_session_incarnation()
	)
	var last_result_ids := (
		transactions.get("_last_simple_crafting_result_ids") as Dictionary
	)
	var ui_tokens := (
		transactions.get(
			"_local_simple_crafting_ui_tokens_by_request_id"
		) as Dictionary
	)
	_expect(
		stone_mill_slot >= 0
		and not last_result_ids.has(REMOTE_PEER_ID)
		and int(ui_tokens.get(77, 0)) == 9001
		and not mp_game.peer_ledger_coordinator.has_pending_envelope(
			REMOTE_PEER_ID,
			&"craft/77"
		)
		and runtime.shown_crafting_results.is_empty()
		and run_state.get_inventory_revision_for_peer(REMOTE_PEER_ID) == 0
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			STONE_MILL_ITEM
		) == 0,
		"客户端无法完整应用权威背包快照时，不能确认request_id、释放UI token或显示制造成功。"
	)

	mp_game.net_simple_crafting_result(
		REMOTE_PEER_ID,
		77,
		"stone_mill",
		String(RunStateStore.CRAFT_RESULT_SUCCESS),
		authoritative_snapshot,
		false,
		net_manager.get_session_participant_incarnation(REMOTE_PEER_ID),
		net_manager.get_game_session_incarnation()
	)
	last_result_ids = (
		transactions.get("_last_simple_crafting_result_ids") as Dictionary
	)
	ui_tokens = (
		transactions.get(
			"_local_simple_crafting_ui_tokens_by_request_id"
		) as Dictionary
	)
	var shown_result := _result_at(runtime.shown_crafting_results, 0)
	_expect(
		int(last_result_ids.get(REMOTE_PEER_ID, 0)) == 77
		and not ui_tokens.has(77)
		and str(shown_result.get("recipe_id", "")) == "stone_mill"
		and str(shown_result.get("result", ""))
		== String(RunStateStore.CRAFT_RESULT_SUCCESS)
		and int(shown_result.get("request_token", 0)) == 9001
		and run_state.get_inventory_item_total_for_peer(
			REMOTE_PEER_ID,
			STONE_MILL_ITEM
		) == 1,
		"坏快照不能毒化去重游标；同一request_id的后续有效权威快照必须仍可确认并释放对应token。"
	)

	mp_game.free()
	net_manager.free()
	runtime.free()
	player.free()
	run_state.free()


func _configure_active_session_member_fixture(
	net_manager: NetManagerStore,
	peer_id: int
) -> void:
	if net_manager == null or peer_id <= 0:
		return
	var fixture_members: Dictionary[int, Dictionary] = {}
	fixture_members[peer_id] = {
		"player_name": "Client",
		"character_id": PlayerCharacterRegistry.DEFAULT_CHARACTER_ID,
		"character_confirmed": true,
		"state": int(NetManagerStore.SessionMemberState.ACTIVE),
		"participant_incarnation": peer_id,
		"reconnect_token": "",
		"grace_expires_msec": 0,
	}
	net_manager.set("_session_members", fixture_members)
	net_manager.set("_session_membership_revision", 1)
	net_manager.loading_session_id = 1


func _find_peer_item_slot(
	run_state: RunStateStore,
	peer_id: int,
	item: PickupConfig
) -> int:
	for slot_index in range(RunStateStore.INVENTORY_CAPACITY):
		if PickupConfig.inventory_identity_matches(
			run_state.get_item_for_peer(peer_id, slot_index),
			item
		):
			return slot_index
	return -1


func _find_snapshot_item_slot(
	snapshot: Dictionary,
	item_config_path: String
) -> int:
	var slots := snapshot.get("slots", []) as Array
	for slot_value in slots:
		var slot := slot_value as Dictionary
		if str(slot.get("config_path", "")) == item_config_path:
			return int(slot.get("slot_index", -1))
	return -1


func _snapshot_contains_exact_item_path(
	snapshot: Dictionary,
	item_config_path: String,
	stack_count: int
) -> bool:
	var slot_index := _find_snapshot_item_slot(snapshot, item_config_path)
	if slot_index < 0:
		return false
	var slots := snapshot.get("slots", []) as Array
	if slot_index >= slots.size():
		return false
	var slot := slots[slot_index] as Dictionary
	return int(slot.get("stack_count", 0)) == stack_count


func _result_at(results: Array[Dictionary], index: int) -> Dictionary:
	if index < 0 or index >= results.size():
		return {}
	return results[index]


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
