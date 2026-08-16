extends SceneTree

const GOLD_WINE_CUP := preload(
	"res://resources/config/collectibles/collectible_gold_wine_cup.tres"
)
const SEA_CUCUMBER := preload(
	"res://resources/config/consumables/sea_cucumber.tres"
)
const GEL := preload("res://resources/config/materials/material_gel.tres")
const WOOD := preload("res://resources/config/materials/material_wood.tres")
const BASKETBALL := preload(
	"res://resources/config/collectibles/collectible_basketball.tres"
)
const OVERLAY_SCENE := preload(
	"res://scene/game_modes/rogue/encounter/rogue_encounter_overlay.tscn"
)

var _failures: PackedStringArray = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_registry_contract()
	_test_inventory_only_cup_availability_and_peer_zero()
	_test_stomp_rewards_and_idempotency()
	_test_gold_cup_atomic_party_bonus_and_snapshot()
	_test_feast_all_or_nothing()
	_test_session_result_pages_and_ack()
	await _test_overlay_manual_result_advance()
	if _failures.is_empty():
		print("ROGUE_ENCOUNTER_INVISIBLE_SEA_CUCUMBER_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_registry_contract() -> void:
	var entries := RogueEncounterRegistry.get_pool_entries(
		RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL
	)
	var config := RogueEncounterRegistry.get_encounter_config(
		RogueEncounterRegistry.INVISIBLE_SEA_CUCUMBER
	)
	var options := RogueEncounterRegistry.get_option_configs(
		RogueEncounterRegistry.INVISIBLE_SEA_CUCUMBER
	)
	_expect(
		entries.has(RogueEncounterRegistry.INVISIBLE_SEA_CUCUMBER)
		and str(config.get("intro_text", "")) == "你注意到了隐形的海参"
		and str(config.get("portrait_texture_path", ""))
		== "res://resources/texture/rogue_encounter/invisible_sea_cucumber.png"
		and str(config.get("encounter_hint", "")).is_empty()
		and bool(config.get("manual_result_page_advance", false))
		and RogueEncounterRegistry.requires_result_ack(
			RogueEncounterRegistry.INVISIBLE_SEA_CUCUMBER
		),
		"隐形海参必须注册指定开场、纯黑轮廓路径、手动翻页与结果屏障。"
	)
	_expect(
		options.size() == 3
		and str(options[0].get("title", "")) == "什么路边玩意"
		and str(options[0].get("description", "")) == "直接一脚踩死"
		and str(options[1].get("title", "")) == "给他一个奖杯"
		and str(options[1].get("description", "")).is_empty()
		and str(options[1].get("icon_texture_path", ""))
		== "res://resources/texture/collectibles/gold_wine_cup.png"
		and str(options[2].get("title", "")) == "海鲜大餐真不错！"
		and str(options[2].get("description", ""))
		== "管他会不会隐身直接做成海线大餐！",
		"隐形海参三个选项必须保留用户指定大小字和奖杯图标。"
	)


func _test_inventory_only_cup_availability_and_peer_zero() -> void:
	var run_state := _new_run_state([1, 2])
	_expect(
		run_state.replace_shared_warehouse_snapshots([
			_make_warehouse_snapshot(701, 0, GOLD_WINE_CUP.resource_path, 1),
		]),
		"可用性测试应准备只在共享仓库中的金酒之杯。"
	)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var unavailable := economy.get_option_availability(
		RogueEncounterRegistry.INVISIBLE_SEA_CUCUMBER,
		[1, 2]
	)
	_expect(
		not bool(unavailable.get("give_gold_wine_cup", true)),
		"共享仓库中的金酒之杯不得解锁奖杯选项。"
	)
	_expect(
		run_state.try_add_item_for_peer(2, GOLD_WINE_CUP),
		"玩家2背包应能放入金酒之杯。"
	)
	var available := economy.get_option_availability(
		RogueEncounterRegistry.INVISIBLE_SEA_CUCUMBER,
		[1, 2]
	)
	_expect(
		bool(available.get("give_gold_wine_cup", false))
		and bool(available.get("cook_sea_cucumber", false)),
		"任一参与玩家背包持杯时奖杯项应解锁，空背包也应允许全员发海参。"
	)
	economy.free()
	run_state.free()

	var local_state := _new_run_state([0])
	_expect(local_state.try_add_item(GOLD_WINE_CUP), "单人本地背包应能持杯。")
	var local_economy := RogueEncounterEconomyCoordinator.new()
	local_economy.configure(local_state)
	_expect(
		local_economy.has_gold_wine_cup_in_player_inventories([0]),
		"peer 0 必须通过本地库存 wire snapshot 正确解锁奖杯项。"
	)
	var local_result := local_economy.resolve_invisible_sea_cucumber(
		RogueEncounterRegistry.OPTION_GIVE_GOLD_WINE_CUP,
		8080,
		[0],
		"sea-cucumber-local-technique"
	)
	_expect(
		bool(local_result.get("resolved", false))
		and local_state.get_inventory_item_total(GOLD_WINE_CUP) == 0
		and local_state.get_player_stat_bonus_value(0, &"attack_damage") == 10
		and local_state.get_player_stat_bonus_value(
			0,
			&"dash_cooldown_reduction"
		) == 1,
		"peer 0 奖杯结算必须扣除本地杯子并写入两项永久增益。"
	)
	local_economy.free()
	local_state.free()


func _test_stomp_rewards_and_idempotency() -> void:
	for reward_is_gel in [true, false]:
		var peers: Array[int] = [11, 12]
		var seed := _find_stomp_seed(reward_is_gel)
		var expected_receiver := peers[
			RogueEncounterRandom.choose_index(
				seed,
				&"invisible_sea_cucumber_stomp_receiver",
				peers.size()
			)
		]
		var expected_item: PickupConfig = GEL if reward_is_gel else WOOD
		var expected_count := 10 if reward_is_gel else 5
		var expected_text := (
			"获得了10个凝胶" if reward_is_gel else "获得了5个木头"
		)
		var run_state := _new_run_state(peers)
		var economy := RogueEncounterEconomyCoordinator.new()
		economy.configure(run_state)
		var result := economy.resolve_invisible_sea_cucumber(
			RogueEncounterRegistry.OPTION_STOMP_SEA_CUCUMBER,
			seed,
			[12, 11, 12],
			"sea-cucumber-stomp-%s" % ("gel" if reward_is_gel else "wood")
		)
		_expect(
			bool(result.get("resolved", false))
			and bool(result.get("reward_granted", false))
			and int(result.get("receiver_peer_id", -1)) == expected_receiver
			and int(result.get("reward_count", -1)) == expected_count
			and str(result.get("reward_text", "")) == expected_text
			and str(result.get("reward_destination", "")) == "inventory"
			and _item_total(run_state, expected_receiver, expected_item)
			== expected_count,
			"踩死海参必须用独立随机盐抽中%s和接收者，并显示精确获得文字。"
			% ("凝胶" if reward_is_gel else "木头")
		)
		var after_first := run_state.export_party_economy_snapshot(
			PackedInt32Array(peers)
		)
		var replay := economy.resolve_invisible_sea_cucumber(
			RogueEncounterRegistry.OPTION_STOMP_SEA_CUCUMBER,
			seed + 1,
			peers,
			"sea-cucumber-stomp-%s" % ("gel" if reward_is_gel else "wood")
		)
		_expect(
			replay == result
			and run_state.export_party_economy_snapshot(
				PackedInt32Array(peers)
			) == after_first,
			"同一踩死 occurrence 重放不得重新抽奖或重复发放。"
		)
		economy.free()
		run_state.free()

	var capacity_seed := _find_stomp_seed(true)
	var capacity_state := _new_run_state([71, 72])
	_fill_inventory(capacity_state, 71)
	var capacity_economy := RogueEncounterEconomyCoordinator.new()
	capacity_economy.configure(capacity_state)
	var capacity_result := capacity_economy.resolve_invisible_sea_cucumber(
		RogueEncounterRegistry.OPTION_STOMP_SEA_CUCUMBER,
		capacity_seed,
		[71, 72],
		"sea-cucumber-stomp-capable-receiver"
	)
	_expect(
		int(capacity_result.get("receiver_peer_id", -1)) == 72
		and _item_total(capacity_state, 72, GEL) == 10,
		"踩死奖励必须只在能完整容纳整批材料的玩家中抽取接收者。"
	)
	capacity_economy.free()
	capacity_state.free()

	var full_state := _new_run_state([73, 74])
	_fill_inventory(full_state, 73)
	_fill_inventory(full_state, 74)
	_expect(
		full_state.replace_shared_warehouse_snapshots([
			_make_warehouse_snapshot(704, 0, "", 0),
		]),
		"踩死满包测试应准备有空位的共享仓库。"
	)
	var full_economy := RogueEncounterEconomyCoordinator.new()
	full_economy.configure(full_state)
	var full_result := full_economy.resolve_invisible_sea_cucumber(
		RogueEncounterRegistry.OPTION_STOMP_SEA_CUCUMBER,
		capacity_seed,
		[73, 74],
		"sea-cucumber-stomp-no-receiver"
	)
	_expect(
		StringName(full_result.get("result_code", &""))
		== RogueEncounterEconomyCoordinator.RESULT_SEA_CUCUMBER_STOMP_DROPPED
		and int(full_result.get("receiver_peer_id", -2)) == -1
		and str(full_result.get("reward_destination", "")) == "discarded"
		and full_state.get_shared_warehouse_item_total(GEL) == 0,
		"无人能完整接收时踩死材料必须明确丢弃，不得改发共享仓库。"
	)
	full_economy.free()
	full_state.free()


func _test_gold_cup_atomic_party_bonus_and_snapshot() -> void:
	var peers: Array[int] = [21, 22]
	var seed := 2122
	var expected_payer := peers[
		RogueEncounterRandom.choose_index(
			seed,
			&"invisible_sea_cucumber_gold_wine_cup_payer",
			peers.size()
		)
	]
	var run_state := _new_run_state(peers)
	for peer_id in peers:
		_expect(
			run_state.try_add_item_for_peer(peer_id, GOLD_WINE_CUP),
			"奖杯付款人测试应给两名玩家各一只杯。"
		)
	var status_revision_before := run_state.get_party_status_ledger_revision()
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var result := economy.resolve_invisible_sea_cucumber(
		RogueEncounterRegistry.OPTION_GIVE_GOLD_WINE_CUP,
		seed,
		[22, 21],
		"sea-cucumber-technique"
	)
	_expect(
		bool(result.get("resolved", false))
		and int(result.get("cup_payer_peer_id", -1)) == expected_payer
		and int(result.get("gold_wine_cup_paid", -1)) == 1
		and _item_total(run_state, expected_payer, GOLD_WINE_CUP) == 0
		and _item_total(
			run_state,
			21 if expected_payer == 22 else 22,
			GOLD_WINE_CUP
		) == 1,
		"多名玩家持杯时必须稳定选择一名背包付款人且只扣一杯。"
	)
	_expect(
		run_state.get_party_status_ledger_revision()
		== status_revision_before + 1,
		"两项全员增益只能共同推进一次 status ledger revision。"
	)
	for peer_id in peers:
		_expect(
			run_state.get_player_stat_bonus_value(peer_id, &"attack_damage") == 10
			and run_state.get_player_stat_bonus_value(
				peer_id,
				&"dash_cooldown_reduction"
			) == 1,
			"每位参与玩家必须在同一账本提交中获得攻击+10与冲刺冷却-1秒。"
		)
	var after_first := run_state.export_party_economy_snapshot(
		PackedInt32Array(peers)
	)
	var replay := economy.resolve_invisible_sea_cucumber(
		RogueEncounterRegistry.OPTION_GIVE_GOLD_WINE_CUP,
		seed + 100,
		peers,
		"sea-cucumber-technique"
	)
	_expect(
		replay == result
		and run_state.export_party_economy_snapshot(
			PackedInt32Array(peers)
		) == after_first,
		"奖杯结算重放不得重复扣杯或叠加永久增益。"
	)

	var remote_state := _new_run_state(peers)
	var remote_economy := RogueEncounterEconomyCoordinator.new()
	remote_economy.configure(remote_state)
	var snapshot := economy.export_snapshot(peers)
	_expect(
		remote_economy.apply_remote_snapshot(snapshot)
		and remote_state.get_player_stat_bonus_value(21, &"attack_damage") == 10
		and remote_state.get_player_stat_bonus_value(
			22,
			&"dash_cooldown_reduction"
		) == 1
		and _item_total(remote_state, expected_payer, GOLD_WINE_CUP) == 0,
		"经济全量快照必须同步奖杯扣除、永久增益和幂等结算结果。"
	)
	var migrated := economy.migrate_result_peer_references(
		result,
		expected_payer,
		99
	)
	_expect(
		int(migrated.get("cup_payer_peer_id", -1)) == 99,
		"重连迁移必须更新奖杯付款人引用。"
	)
	remote_economy.free()
	remote_state.free()
	economy.free()
	run_state.free()


func _test_feast_all_or_nothing() -> void:
	var peers: Array[int] = [31, 32, 33]
	var run_state := _new_run_state(peers)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	_expect(
		economy.can_grant_sea_cucumber_to_all(peers),
		"所有参与玩家有空位时海鲜大餐应可选。"
	)
	var result := economy.resolve_invisible_sea_cucumber(
		RogueEncounterRegistry.OPTION_COOK_SEA_CUCUMBER,
		313233,
		peers,
		"sea-cucumber-feast"
	)
	var rewards := result.get("consumable_rewards", []) as Array
	_expect(
		bool(result.get("resolved", false))
		and bool(result.get("reward_granted", false))
		and rewards.size() == peers.size(),
		"海鲜大餐必须返回每名参与玩家一条已发放记录。"
	)
	for peer_id in peers:
		_expect(
			_item_total(run_state, peer_id, SEA_CUCUMBER) == 1,
			"海鲜大餐必须给玩家%d恰好一个海参。" % peer_id
		)
	var replay := economy.resolve_invisible_sea_cucumber(
		RogueEncounterRegistry.OPTION_COOK_SEA_CUCUMBER,
		999,
		peers,
		"sea-cucumber-feast"
	)
	_expect(
		replay == result,
		"海鲜大餐 occurrence 重放必须复用首次全员发放结果。"
	)
	economy.free()
	run_state.free()

	var full_state := _new_run_state([41, 42])
	_fill_inventory(full_state, 42)
	var full_economy := RogueEncounterEconomyCoordinator.new()
	full_economy.configure(full_state)
	var before := full_state.export_party_economy_snapshot(
		PackedInt32Array([41, 42])
	)
	var availability := full_economy.get_option_availability(
		RogueEncounterRegistry.INVISIBLE_SEA_CUCUMBER,
		[41, 42]
	)
	_expect(
		not bool(availability.get("cook_sea_cucumber", true)),
		"任一参与玩家背包无容量时海鲜大餐选项必须灰暗。"
	)
	var full_result := full_economy.resolve_invisible_sea_cucumber(
		RogueEncounterRegistry.OPTION_COOK_SEA_CUCUMBER,
		4142,
		[41, 42],
		"sea-cucumber-feast-full"
	)
	_expect(
		StringName(full_result.get("result_code", &""))
		== RogueEncounterEconomyCoordinator.RESULT_SEA_CUCUMBER_PARTY_INVENTORY_FULL
		and full_state.export_party_economy_snapshot(
			PackedInt32Array([41, 42])
		) == before,
		"容量竞态下也必须整队不发放，禁止只给部分玩家。"
	)
	full_economy.free()
	full_state.free()


func _test_session_result_pages_and_ack() -> void:
	var run_state := _new_run_state([51])
	_expect(
		run_state.try_add_item_for_peer(51, GOLD_WINE_CUP),
		"Session奖杯分支应准备金酒之杯。"
	)
	var economy := RogueEncounterEconomyCoordinator.new()
	economy.configure(run_state)
	var session := RogueEncounterSession.new()
	session.initialize_authority(economy, [51])
	var seed := _seed_for_encounter(
		RogueEncounterRegistry.INVISIBLE_SEA_CUCUMBER
	)
	_expect(
		session.start_for_node(
			901,
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			seed,
			[51]
		),
		"Session必须能从神奇遭遇池启动隐形海参。"
	)
	var state := session.export_state()
	_expect(
		str(state.get("encounter_id", "")) == "invisible_sea_cucumber"
		and bool((state.get("option_availability", {}) as Dictionary).get(
			"give_gold_wine_cup",
			false
		)),
		"开场快照必须携带隐形海参ID和权威奖杯可用性。"
	)
	_expect(
		session.submit_intro_ack(
			51,
			session.get_occurrence_key(),
			session.get_revision()
		),
		"玩家应能确认隐形海参开场。"
	)
	_expect(
		session.submit_vote(
			51,
			session.get_occurrence_key(),
			session.get_revision(),
			RogueEncounterRegistry.OPTION_GIVE_GOLD_WINE_CUP
		),
		"玩家应能选择可用的奖杯项。"
	)
	var result_state := session.export_state()
	var pages := result_state.get("result_pages", []) as Array
	_expect(
		session.get_phase() == RogueEncounterSession.PHASE_RESULT
		and pages.size() == 2
		and str((pages[0] as Dictionary).get("text", ""))
		== "海参十分高兴，传授了你一些技术"
		and str((pages[1] as Dictionary).get("text", ""))
		== "所有玩家的冲刺冷却时间缩短1秒，攻击力+10"
		and result_state.get("round_recipient_peer_ids", []) == [51],
		"奖杯结果必须同步两页精确文字并等待当轮玩家确认。"
	)
	var remote_state := _new_run_state([51])
	var remote_economy := RogueEncounterEconomyCoordinator.new()
	remote_economy.configure(remote_state)
	var remote_session := RogueEncounterSession.new()
	remote_session.initialize_remote(remote_economy)
	_expect(
		remote_session.apply_remote_state(result_state)
		and remote_session.export_state() == result_state,
		"隐形海参结果、扣杯与永久状态必须通过Session快照无损重连。"
	)
	_expect(
		session.submit_result_ack(
			51,
			session.get_occurrence_key(),
			int(result_state.get("result_sequence", 0))
		)
		and session.get_phase() == RogueEncounterSession.PHASE_COMPLETED,
		"全员读完两页结果后才可完成隐形海参节点。"
	)
	remote_session.free()
	remote_economy.free()
	remote_state.free()
	session.free()
	economy.free()
	run_state.free()


func _test_overlay_manual_result_advance() -> void:
	var overlay := OVERLAY_SCENE.instantiate() as RogueEncounterOverlay
	root.add_child(overlay)
	var hold_count := [0]
	var ack_count := [0]
	overlay.result_hold_completed.connect(
		func(_key: String, _revision: int) -> void: hold_count[0] += 1
	)
	overlay.result_ack_requested.connect(
		func(_key: String, _sequence: int) -> void: ack_count[0] += 1
	)
	overlay.configure_local_context(61, {61: "玩家"}, {})
	overlay.visible = true
	overlay.encounter_content.visible = true
	overlay.encounter_is_revealed = true
	overlay.apply_state(_make_overlay_result_state())
	var confirm := InputEventAction.new()
	confirm.action = &"interact"
	confirm.pressed = true
	_expect(
		overlay.result_page_index == 0
		and overlay.typewriter.is_revealing()
		and overlay.prompt_label.visible,
		"隐形海参第一页结果应逐字显示并提示点击继续。"
	)
	overlay._input(confirm)
	_expect(
		not overlay.typewriter.is_revealing()
		and overlay.result_page_index == 0,
		"第一页首次确认只能补全文字，不能翻页。"
	)
	await create_timer(RogueEncounterOverlay.RESULT_PAGE_GAP_SECONDS + 0.08).timeout
	_expect(
		overlay.result_page_index == 0 and hold_count[0] == 0,
		"隐形海参结果不得沿用其他遭遇的自动翻页。"
	)
	overlay._input(confirm)
	_expect(
		overlay.result_page_index == 1
		and overlay.typewriter.is_revealing(),
		"第二次确认必须主动进入第二页技术效果文字。"
	)
	overlay._input(confirm)
	_expect(
		not overlay.typewriter.is_revealing()
		and hold_count[0] == 0,
		"第二页首次确认也只能补全文字，不能直接完成结果。"
	)
	await create_timer(0.1).timeout
	_expect(
		hold_count[0] == 0 and ack_count[0] == 0,
		"最后一页必须等待玩家再次确认才进入停留与ack。"
	)
	overlay._input(confirm)
	await create_timer(RogueEncounterOverlay.RESULT_HOLD_SECONDS - 0.1).timeout
	_expect(
		hold_count[0] == 0 and ack_count[0] == 0,
		"最后确认后仍必须保留既有1.5秒结果停留。"
	)
	await create_timer(0.18).timeout
	_expect(
		hold_count[0] == 1 and ack_count[0] == 1,
		"手动结果末页停留结束后必须恰好发出一次完成与ack。"
	)
	overlay.hide_immediately()
	overlay.free()


func _make_overlay_result_state() -> Dictionary:
	return {
		"revision": 4,
		"phase": "result",
		"node_id": 902,
		"node_content_seed": 9092,
		"occurrence_key": "902:9092",
		"encounter_id": "invisible_sea_cucumber",
		"remaining_seconds": 0.0,
		"participant_peer_ids": [61],
		"active_peer_ids": [61],
		"intro_confirmed_peer_ids": [61],
		"votes": [{"peer_id": 61, "option_id": "give_gold_wine_cup"}],
		"abstained_peer_ids": [],
		"option_availability": {
			"stomp_sea_cucumber": true,
			"give_gold_wine_cup": true,
			"cook_sea_cucumber": true,
		},
		"winning_option": "give_gold_wine_cup",
		"economy_result": {
			"result_code": "sea_cucumber_technique",
		},
		"result_text": "所有玩家的冲刺冷却时间缩短1秒，攻击力+10",
		"result_pages": [
			{
				"speaker": "",
				"text": "海参十分高兴，传授了你一些技术",
				"is_narration": true,
			},
			{
				"speaker": "",
				"text": "所有玩家的冲刺冷却时间缩短1秒，攻击力+10",
				"is_narration": true,
			},
		],
		"result_sequence": 1,
		"round_recipient_peer_ids": [61],
		"personal_result_pages": {},
	}


func _find_stomp_seed(expect_gel: bool) -> int:
	for seed in range(1, 10000):
		if (
			RogueEncounterRandom.choose_index(
				seed,
				&"invisible_sea_cucumber_stomp_reward_kind",
				2
			) == 0
		) == expect_gel:
			return seed
	return -1


func _seed_for_encounter(encounter_id: StringName) -> int:
	for seed in range(1, 100000):
		if RogueEncounterRegistry.select_encounter(
			RogueEncounterRegistry.MAGICAL_ENCOUNTER_POOL,
			seed
		) == encounter_id:
			return seed
	return -1


func _new_run_state(peer_ids: Array[int]) -> RunStateStore:
	var run_state := RunStateStore.new()
	run_state.begin_new_run(&"weishidaier", false)
	for peer_id in peer_ids:
		if peer_id > 0:
			run_state.register_multiplayer_peer_state(peer_id)
	return run_state


func _item_total(
	run_state: RunStateStore,
	peer_id: int,
	item: PickupConfig
) -> int:
	return (
		run_state.get_inventory_item_total(item)
		if peer_id == 0
		else run_state.get_inventory_item_total_for_peer(peer_id, item)
	)


func _fill_inventory(run_state: RunStateStore, peer_id: int) -> void:
	for _slot_index in RunStateStore.INVENTORY_CAPACITY:
		_expect(
			run_state.try_add_item_for_peer(peer_id, BASKETBALL),
			"满包测试应能用不可堆叠篮球填满玩家%d背包。" % peer_id
		)


func _make_warehouse_snapshot(
	warehouse_net_id: int,
	revision: int,
	config_path: String,
	count: int
) -> Dictionary:
	var slots: Array[Dictionary] = []
	for slot_index in RunStateStore.INVENTORY_CAPACITY:
		slots.append({
			"slot_index": slot_index,
			"config_path": config_path if slot_index == 0 and count > 0 else "",
			"stack_count": count if slot_index == 0 else 0,
		})
	return {
		"warehouse_net_id": warehouse_net_id,
		"revision": revision,
		"slots": slots,
	}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
