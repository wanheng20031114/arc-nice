extends SceneTree

const SHOP_CONFIG: RogueUndergroundShopConfig = preload(
	"res://resources/config/rogue_shop/shallow_mine_underground_shop.tres"
)
const FLOOR_DEFINITION: RogueRouteFloorDefinition = preload(
	"res://resources/config/rogue_route/shallow_mine_floor.tres"
)
const HEALTH_POTION: PickupConfig = preload(
	"res://resources/config/consumables/healing_potion.tres"
)
const LARGE_HEALING_POTION: PickupConfig = preload(
	"res://resources/config/consumables/large_healing_potion.tres"
)
const ROCK_POTION: PickupConfig = preload(
	"res://resources/config/consumables/rock_potion.tres"
)
const LARGE_ROCK_POTION: PickupConfig = preload(
	"res://resources/config/consumables/large_rock_potion.tres"
)
const MATERIAL_WOOD: PickupConfig = preload(
	"res://resources/config/materials/material_wood.tres"
)
const LOCKED_ITEM: PickupConfig = preload(
	"res://resources/config/fate/xiaocong_fate_stone.tres"
)
const BUILDING_ITEM: PickupConfig = preload(
	"res://resources/config/buildings/building_simple_fence.tres"
)
const UNSUPPORTED_ITEM: PickupConfig = preload(
	"res://resources/config/pickup_triggered_items/speed_boots.tres"
)
const FLYING_ENVELOPE: PickupConfig = preload(
	"res://resources/config/collectibles/collectible_flying_envelope.tres"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_config_and_offer_generation()
	_test_session_contract()
	_test_four_player_exit_barrier()
	_test_economy_transactions()
	call_deferred("_finish")


func _test_config_and_offer_generation() -> void:
	_expect(SHOP_CONFIG != null, "浅层矿洞地下商店配置必须能够加载。")
	_expect(
		SHOP_CONFIG.validate_config().is_empty(),
		"地下商店配置必须通过校验：%s" % [SHOP_CONFIG.validate_config()]
	)
	_expect(
		RogueUndergroundShopConfig.RUNTIME_CONTRACT_SCHEMA == 2,
		"地下商店运行契约 schema 必须升级为 2。"
	)
	var expected_consumable_prices := _get_expected_consumable_prices()
	var configured_consumable_paths: Dictionary = {}
	for listing in SHOP_CONFIG.consumable_listings:
		if listing == null:
			continue
		var listing_path := listing.get_config_path()
		configured_consumable_paths[listing_path] = true
		_expect(
			expected_consumable_prices.has(listing_path)
			and listing.purchase_price == int(expected_consumable_prices[listing_path])
			and listing.sell_price == int(expected_consumable_prices[listing_path]),
			"四种消耗品 listing 必须使用约定的同买同卖价格：%s" % listing_path
		)
	_expect(
		configured_consumable_paths.size() == expected_consumable_prices.size(),
		"地下商店必须且仅配置四种计划内消耗品。"
	)
	_expect(
		FLOOR_DEFINITION.underground_shop_config == SHOP_CONFIG,
		"楼层定义必须显式引用地下商店配置。"
	)
	_expect(
		not FLOOR_DEFINITION.compute_runtime_contract_hash().is_empty(),
		"楼层运行契约必须纳入地下商店配置。"
	)
	var character_id := PlayerCharacterRegistry.HOE_CAT_ID
	var compatible_pool := (
		RogueUndergroundShopOfferGenerator.get_compatible_collectible_pool(
			character_id
		)
	)
	var compatible_paths: Dictionary = {}
	for item in compatible_pool:
		compatible_paths[item.resource_path] = true
	var first := RogueUndergroundShopOfferGenerator.generate_offers(
		SHOP_CONFIG,
		71031,
		"player:alpha",
		character_id
	)
	var repeated := RogueUndergroundShopOfferGenerator.generate_offers(
		SHOP_CONFIG,
		71031,
		"player:alpha",
		character_id
	)
	_expect(first == repeated, "同节点、同稳定参与键的货架必须逐字段一致。")
	_expect(first.size() == 8, "每名玩家的地下商店货架必须固定为 8 格。")
	_audit_offer_set(first, compatible_paths)
	var reordered_config := SHOP_CONFIG.duplicate() as RogueUndergroundShopConfig
	reordered_config.collectible_count_choices = PackedInt32Array([6, 4, 5])
	var reversed_listings: Array[RogueUndergroundShopListing] = []
	for listing_index in range(
		reordered_config.consumable_listings.size() - 1,
		-1,
		-1
	):
		reversed_listings.append(
			reordered_config.consumable_listings[listing_index]
		)
	reordered_config.consumable_listings = reversed_listings
	_expect(
		reordered_config.validate_config().is_empty()
		and reordered_config.compute_runtime_contract_hash()
		== SHOP_CONFIG.compute_runtime_contract_hash()
		and RogueUndergroundShopOfferGenerator.generate_offers(
			reordered_config,
			71031,
			"player:alpha",
			character_id
		) == first,
		"数量候选与 listing 顺序不属于 contract，重排后必须仍生成同一货架。"
	)
	var changed := false
	for seed_offset in range(1, 12):
		var candidate := RogueUndergroundShopOfferGenerator.generate_offers(
			SHOP_CONFIG,
			71031 + seed_offset,
			"player:alpha",
			character_id
		)
		if candidate != first:
			changed = true
			break
	_expect(changed, "不同商店节点内容种子必须能够生成不同货架。")
	_expect(
		RogueUndergroundShopOfferGenerator.generate_offers(
			SHOP_CONFIG,
			71031,
			"player:beta",
			character_id
		) != first,
		"同节点的不同稳定参与键应生成个人独立货架。"
	)

	var collectible_count_distribution := {4: 0, 5: 0, 6: 0}
	var consumable_selection_counts := _get_empty_consumable_counts()
	for seed_value in range(900):
		var offers := RogueUndergroundShopOfferGenerator.generate_offers(
			SHOP_CONFIG,
			seed_value,
			"distribution-player",
			character_id
		)
		var collectible_count := _count_collectible_offers(offers)
		_audit_offer_set(offers, compatible_paths)
		for generated_offer in offers:
			if str(generated_offer.get("kind", "")) == "consumable":
				var generated_path := str(generated_offer.get("config_path", ""))
				if consumable_selection_counts.has(generated_path):
					consumable_selection_counts[generated_path] += 1
		_expect(
			collectible_count_distribution.has(collectible_count),
			"收藏品格数只能为 4、5 或 6。"
		)
		if collectible_count_distribution.has(collectible_count):
			collectible_count_distribution[collectible_count] += 1
	for collectible_count in [4, 5, 6]:
		_expect(
			abs(int(collectible_count_distribution[collectible_count]) - 300) < 70,
			"4/5/6 收藏品数量应使用等概率选择，当前分布：%s"
			% [collectible_count_distribution]
		)
	var total_consumable_selections := 0
	for selection_count in consumable_selection_counts.values():
		total_consumable_selections += int(selection_count)
	var expected_selections_per_consumable := total_consumable_selections / 4.0
	for consumable_path in consumable_selection_counts:
		_expect(
			abs(
				int(consumable_selection_counts[consumable_path])
				- expected_selections_per_consumable
			) < 100.0,
			"四种消耗品应等概率入选，当前分布：%s" % [consumable_selection_counts]
		)


func _audit_offer_set(
	offers: Array[Dictionary],
	compatible_paths: Dictionary
) -> void:
	var collectible_paths: Dictionary = {}
	var consumable_paths: Dictionary = {}
	var expected_consumable_prices := _get_expected_consumable_prices()
	for offer_index in offers.size():
		var offer := offers[offer_index]
		_expect(
			int(offer.get("offer_index", -1)) == offer_index,
			"报价索引必须与 4×2 货架槽位一致。"
		)
		_expect(not bool(offer.get("purchased", true)), "新报价不得预先售罄。")
		var config_path := str(offer.get("config_path", ""))
		var kind := str(offer.get("kind", ""))
		if kind == "consumable":
			_expect(
				expected_consumable_prices.has(config_path),
				"消耗品报价必须来自四条 typed listing：%s" % config_path
			)
			_expect(
				not consumable_paths.has(config_path),
				"同一货架的消耗品必须不放回抽取。"
			)
			consumable_paths[config_path] = true
			if expected_consumable_prices.has(config_path):
				_expect(
					int(offer.get("price", 0))
					== int(expected_consumable_prices[config_path]),
					"消耗品购买价必须来自 typed listing。"
				)
			continue
		_expect(kind == "collectible", "报价 kind 只能为 collectible 或 consumable。")
		_expect(compatible_paths.has(config_path), "收藏品必须来自当前角色兼容的标准池。")
		_expect(not collectible_paths.has(config_path), "同一货架收藏品路径不得重复。")
		collectible_paths[config_path] = true
		var item := load(config_path) as PickupConfig
		_expect(
			item != null
			and item.collectible_rarity
			!= PickupConfig.CollectibleRarity.SPECIAL,
			"SPECIAL 收藏品不得进入地下商店。"
		)
		if item == null:
			continue
		var band := SHOP_CONFIG.get_collectible_price_band(item.collectible_rarity)
		var price := int(offer.get("price", 0))
		_expect(
			price >= band.x
			and price <= band.y
			and price % band.z == 0,
			"收藏品价格必须处于稀有度区间并按步长量化：%s" % offer
		)
	_expect(
		consumable_paths.size() == 8 - collectible_paths.size(),
		"收藏品以外的格子必须是不重复的消耗品。"
	)


func _test_session_contract() -> void:
	var offers_a := RogueUndergroundShopOfferGenerator.generate_offers(
		SHOP_CONFIG,
		9001,
		"stable:a",
		PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	)
	var offers_b := RogueUndergroundShopOfferGenerator.generate_offers(
		SHOP_CONFIG,
		9001,
		"stable:b",
		PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	)
	var session := RogueUndergroundShopSession.new()
	_expect(
		session.start_authoritative(
			"floor:1|node:5|visit:1",
			12,
			{1: offers_a, 2: offers_b}
		),
		"Host 必须能够以每人私有报价启动商店会话。"
	)
	var snapshot_a := session.export_snapshot_for_peer(1)
	_expect(snapshot_a.get("offers", []) == offers_a, "目标快照只应携带目标玩家报价。")
	_expect(not snapshot_a.has("offers_by_peer"), "快照不得泄漏其他玩家的私有货架。")
	var client_session := RogueUndergroundShopSession.new()
	_expect(client_session.apply_snapshot(snapshot_a), "客户端必须能够应用目标快照。")
	_expect(client_session.apply_snapshot(snapshot_a), "完全相同的同 revision 快照必须幂等。")
	var enriched_snapshot := snapshot_a.duplicate(true)
	enriched_snapshot["inventory_revision"] = 7
	enriched_snapshot["xirang_revision"] = 9
	enriched_snapshot["party_economy_snapshot"] = {"schema_version": 3}
	enriched_snapshot["sell_slots"] = [{"slot_index": 0}]
	enriched_snapshot["transaction_result"] = {"result_code": "purchased"}
	_expect(
		client_session.apply_snapshot(enriched_snapshot),
		"同 revision 快照的路线经济附加字段不得破坏 Session 幂等应用。"
	)
	var conflicting_snapshot := snapshot_a.duplicate(true)
	(conflicting_snapshot["offers"] as Array)[0]["price"] = 999999
	_expect(
		not client_session.apply_snapshot(conflicting_snapshot),
		"同 occurrence、同 revision 的不同内容必须拒绝。"
	)
	var legacy_kind_snapshot := snapshot_a.duplicate(true)
	(legacy_kind_snapshot["offers"] as Array)[0]["kind"] = "health_potion"
	_expect(
		not RogueUndergroundShopSession.new().apply_snapshot(legacy_kind_snapshot),
		"旧 health_potion 报价 kind 必须拒绝，只接受泛化后的 consumable。"
	)
	var duplicate_participant := snapshot_a.duplicate(true)
	duplicate_participant["participant_peer_ids"] = [1, 1]
	_expect(not client_session.apply_snapshot(duplicate_participant), "参与者不得重复。")
	var invalid_ready := snapshot_a.duplicate(true)
	invalid_ready["phase"] = RogueUndergroundShopSession.Phase.READY_TO_DEPART
	_expect(not client_session.apply_snapshot(invalid_ready), "仍有等待者时不得应用 READY 快照。")
	var invalid_target := snapshot_a.duplicate(true)
	invalid_target["target_peer_id"] = 99
	_expect(not client_session.apply_snapshot(invalid_target), "非参与目标不得携带货架。")
	var reconnect_session := RogueUndergroundShopSession.new()
	_expect(
		reconnect_session.start_authoritative(
			"shop:reconnect",
			20,
			{7: offers_a, 8: offers_b}
		),
		"重连原子迁移测试会话必须启动。"
	)
	_expect(reconnect_session.remove_peer(7), "断线必须立即把旧 peer 视为退出。")
	var migration_revisions: Array[int] = []
	reconnect_session.session_changed.connect(
		func(revision: int) -> void: migration_revisions.append(revision)
	)
	var revision_before_migration := reconnect_session.get_session_revision()
	_expect(
		reconnect_session.migrate_peer_as_exited(7, 70),
		"认证重连必须原子迁移为新 peer 的已退出旁观者。"
	)
	var migrated_snapshot := reconnect_session.export_snapshot_for_peer(70)
	_expect(
		reconnect_session.get_session_revision() == revision_before_migration + 1
		and migration_revisions.size() == 1
		and bool(migrated_snapshot.get("target_exited", false))
		and (migrated_snapshot.get("offers", []) as Array).is_empty()
		and RogueUndergroundShopSession.new().apply_snapshot(migrated_snapshot),
		"old→new 迁移必须只发布一次 revision，且发布的目标快照始终可解码。"
	)

	var exit_a := session.submit_exit(
		1,
		session.get_occurrence_key(),
		session.get_session_revision()
	)
	_expect(bool(exit_a.get("success", false)), "第一名玩家应可提交退出确认。")
	_expect(session.add_exited_spectator(3), "重连的新 peer 必须登记为已退出旁观者。")
	var spectator_snapshot := session.export_snapshot_for_peer(3)
	_expect(
		bool(spectator_snapshot.get("target_exited", false))
		and (spectator_snapshot.get("offers", []) as Array).is_empty()
		and RogueUndergroundShopSession.new().apply_snapshot(spectator_snapshot),
		"重连玩家快照必须不含货架并直接保持路线地图状态。"
	)
	var stale_exit_b := session.submit_exit(
		2,
		session.get_occurrence_key(),
		int(exit_a.get("session_revision", 0)) - 1
	)
	_expect(not bool(stale_exit_b.get("success", true)), "旧 session revision 退出必须拒绝。")
	_expect(
		bool(session.submit_exit(
			2,
			session.get_occurrence_key(),
			session.get_session_revision()
		).get("success", false)),
		"最后一名玩家退出后应完成屏障。"
	)
	_expect(session.can_depart() and session.get_waiting_peer_ids().is_empty(), "全员退出后才允许房主继续。")
	var ready_revision := session.get_session_revision()
	_expect(session.begin_departing(ready_revision), "路线移动前必须封存会话。")
	_expect(
		session.cancel_departing(session.get_session_revision()),
		"路线 CAS 失败时必须能回滚为 READY。"
	)
	_expect(session.can_depart(), "回滚后房主必须仍可重试路线移动。")
	_expect(
		session.begin_departing(session.get_session_revision()),
		"回滚后应可再次封存。"
	)
	_expect(session.close(), "路线移动成功后才能关闭已封存会话。")


func _test_four_player_exit_barrier() -> void:
	var participant_offers: Dictionary = {}
	for peer_id in range(1, 5):
		var offers := RogueUndergroundShopOfferGenerator.generate_offers(
			SHOP_CONFIG,
			91_337,
			"four-player:%d" % peer_id,
			PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
		)
		_expect(offers.size() == 8, "四人会话中的每名玩家都必须拥有独立 8 格货架。")
		participant_offers[peer_id] = offers
	var session := RogueUndergroundShopSession.new()
	_expect(
		session.start_authoritative("shop:four-player", 31, participant_offers),
		"四人地下商店会话必须能够启动。"
	)
	for peer_id in range(1, 4):
		var result := session.submit_exit(
			peer_id,
			session.get_occurrence_key(),
			session.get_session_revision()
		)
		_expect(bool(result.get("success", false)), "前3名玩家应能独立退出商店。")
		_expect(
			not session.can_depart(),
			"四人会话中仍有玩家未退出时，房主不得推进路线。"
		)
	_expect(
		session.get_waiting_peer_ids() == [4],
		"前三人退出后，屏障必须只等待最后一名在线玩家。"
	)
	var final_result := session.submit_exit(
		4,
		session.get_occurrence_key(),
		session.get_session_revision()
	)
	_expect(
		bool(final_result.get("success", false)) and session.can_depart(),
		"四人全部退出后才应解锁房主路线操作。"
	)


func _test_economy_transactions() -> void:
	var run_state := RunStateStore.new()
	root.add_child(run_state)
	run_state.begin_new_run(PlayerCharacterRegistry.DEFAULT_CHARACTER_ID, false)
	run_state.ensure_multiplayer_peer_state(1)
	run_state.ensure_multiplayer_peer_state(2)
	_expect(run_state.set_party_xirang_balance(1, 20000), "玩家1息壤余额必须可初始化。")
	_expect(run_state.set_party_xirang_balance(2, 20000), "玩家2息壤余额必须可初始化。")
	var offers_a := RogueUndergroundShopOfferGenerator.generate_offers(
		SHOP_CONFIG,
		1771,
		"economy:a",
		PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	)
	var offers_b := RogueUndergroundShopOfferGenerator.generate_offers(
		SHOP_CONFIG,
		1771,
		"economy:b",
		PlayerCharacterRegistry.DEFAULT_CHARACTER_ID
	)
	var session := RogueUndergroundShopSession.new()
	_expect(
		session.start_authoritative("shop:economy", 4, {1: offers_a, 2: offers_b}),
		"经济测试会话必须启动。"
	)
	var coordinator := RogueUndergroundShopEconomyCoordinator.new()
	root.add_child(coordinator)
	_expect(
		coordinator.configure(SHOP_CONFIG, run_state, session),
		"地下商店经济协调器必须完成显式配置。"
	)
	var offer := session.get_offer(1, 0)
	var balance_before := run_state.get_party_xirang_balance(1)
	var purchase_shelf_revision := session.get_shelf_revision(1)
	var purchase_inventory_revision := run_state.get_inventory_revision_for_peer(1)
	var purchase_xirang_revision := run_state.get_party_xirang_ledger_revision()
	var purchase := coordinator.submit_purchase(
		1,
		"purchase-1",
		session.get_occurrence_key(),
		0,
		purchase_shelf_revision,
		purchase_inventory_revision,
		purchase_xirang_revision
	)
	_expect(bool(purchase.get("success", false)), "购买必须以背包+息壤 CAS 成功。")
	_expect(
		run_state.get_party_xirang_balance(1)
		== balance_before - int(offer["price"]),
		"购买必须扣除个人息壤。"
	)
	_expect(
		bool(session.get_offer(1, 0).get("purchased", false))
		and not bool(session.get_offer(2, 0).get("purchased", false)),
		"售罄状态必须仅属于购买者的个人货架。"
	)
	var duplicate := coordinator.submit_purchase(
		1,
		"purchase-1",
		session.get_occurrence_key(),
		0,
		purchase_shelf_revision,
		purchase_inventory_revision,
		purchase_xirang_revision
	)
	_expect(duplicate == purchase, "完全相同 request ID 的重试必须返回缓存结果。")
	var reused := coordinator.submit_purchase(
		1,
		"purchase-1",
		session.get_occurrence_key(),
		1,
		0,
		0,
		2
	)
	_expect(
		str(reused.get("result_code", "")) == "request_id_reused",
		"同 request ID 更换载荷必须拒绝。"
	)

	var bought_slot := _find_inventory_slot_for_path(
		run_state,
		1,
		str(offer["config_path"])
	)
	_expect(bought_slot >= 0, "购买物品必须实际进入购买者背包。")
	var sell_balance_before := run_state.get_party_xirang_balance(1)
	var sell := coordinator.submit_sell(
		1,
		"sell-1",
		session.get_occurrence_key(),
		bought_slot,
		str(offer["config_path"]),
		run_state.get_inventory_revision_for_peer(1),
		run_state.get_party_xirang_ledger_revision()
	)
	_expect(bool(sell.get("success", false)), "购买物品必须可按类型回收。")
	_expect(
		run_state.get_party_xirang_balance(1)
		== sell_balance_before + int(sell["price"]),
		"出售所得必须进入玩家个人息壤账本。"
	)
	var consumable_offer_index := _find_available_offer_by_kind(
		session,
		1,
		"consumable"
	)
	_expect(consumable_offer_index >= 0, "同价往返测试必须找到未售罄消耗品。")
	if consumable_offer_index >= 0:
		var consumable_offer := session.get_offer(1, consumable_offer_index)
		var roundtrip_balance := run_state.get_party_xirang_balance(1)
		var consumable_purchase := coordinator.submit_purchase(
			1,
			"purchase-consumable-roundtrip",
			session.get_occurrence_key(),
			consumable_offer_index,
			session.get_shelf_revision(1),
			run_state.get_inventory_revision_for_peer(1),
			run_state.get_party_xirang_ledger_revision(),
			session.get_session_revision()
		)
		var consumable_slot := _find_inventory_slot_for_path(
			run_state,
			1,
			str(consumable_offer.get("config_path", ""))
		)
		var consumable_sell := coordinator.submit_sell(
			1,
			"sell-consumable-roundtrip",
			session.get_occurrence_key(),
			consumable_slot,
			str(consumable_offer.get("config_path", "")),
			run_state.get_inventory_revision_for_peer(1),
			run_state.get_party_xirang_ledger_revision(),
			session.get_session_revision()
		)
		_expect(
			bool(consumable_purchase.get("success", false))
			and bool(consumable_sell.get("success", false))
			and int(consumable_sell.get("price", 0))
			== int(consumable_offer.get("price", -1))
			and run_state.get_party_xirang_balance(1) == roundtrip_balance,
			"计划内消耗品必须按 listing 同价买卖，往返后余额不变。"
		)

	_expect(run_state.try_add_item_count_for_peer(1, HEALTH_POTION, 3), "测试药瓶必须可叠加。")
	var potion_slot := _find_inventory_slot_for_path(run_state, 1, HEALTH_POTION.resource_path)
	var potion_sell := coordinator.submit_sell(
		1,
		"sell-potion",
		session.get_occurrence_key(),
		potion_slot,
		HEALTH_POTION.resource_path,
		run_state.get_inventory_revision_for_peer(1),
		run_state.get_party_xirang_ledger_revision()
	)
	_expect(
		bool(potion_sell.get("success", false))
		and int(potion_sell.get("remaining_stack_count", -1)) == 2
		and int(potion_sell.get("price", 0)) == 50,
		"出售堆叠药瓶每次只能回收 1 件并原地更新数量。"
	)
	_expect(run_state.try_add_item_for_peer(1, MATERIAL_WOOD), "测试材料必须可加入背包。")
	var wood_slot := _find_inventory_slot_for_path(run_state, 1, MATERIAL_WOOD.resource_path)
	var wood_balance := run_state.get_party_xirang_balance(1)
	var wood_sell := coordinator.submit_sell(
		1,
		"sell-material",
		session.get_occurrence_key(),
		wood_slot,
		MATERIAL_WOOD.resource_path,
		run_state.get_inventory_revision_for_peer(1),
		run_state.get_party_xirang_ledger_revision(),
		session.get_session_revision()
	)
	_expect(
		bool(wood_sell.get("success", false))
		and int(wood_sell.get("price", 0)) == 10
		and run_state.get_party_xirang_balance(1) == wood_balance + 10,
		"物资出售必须单次移除 1 件并获得 10 息壤。"
	)
	var sale_collectible := CollectibleRegistry.get_standard_random_pool()[0]
	_expect(run_state.try_add_item_for_peer(1, sale_collectible), "测试收藏品必须可加入背包。")
	var collectible_slot := _find_inventory_slot_for_path(
		run_state,
		1,
		sale_collectible.resource_path
	)
	var collectible_sell := coordinator.submit_sell(
		1,
		"sell-collectible",
		session.get_occurrence_key(),
		collectible_slot,
		sale_collectible.resource_path,
		run_state.get_inventory_revision_for_peer(1),
		run_state.get_party_xirang_ledger_revision(),
		session.get_session_revision()
	)
	_expect(
		bool(collectible_sell.get("success", false))
		and int(collectible_sell.get("price", 0)) == 100,
		"收藏品出售必须单次获得 100 息壤。"
	)
	_expect(run_state.try_add_item_for_peer(1, LOCKED_ITEM), "测试锁定物品必须可加入背包。")
	_expect(run_state.try_add_item_for_peer(1, BUILDING_ITEM), "测试建筑物品必须可加入背包。")
	_expect(coordinator.get_sell_price(MATERIAL_WOOD) == 10, "物资回收价必须为 10。")
	_expect(coordinator.get_sell_price(HEALTH_POTION) == 50, "治疗血瓶回收价必须为 50。")
	_expect(
		coordinator.get_sell_price(LARGE_HEALING_POTION) == 200,
		"大号治疗血瓶回收价必须为 200。"
	)
	_expect(coordinator.get_sell_price(ROCK_POTION) == 70, "岩石药水回收价必须为 70。")
	_expect(
		coordinator.get_sell_price(LARGE_ROCK_POTION) == 280,
		"大号岩石药水回收价必须为 280。"
	)
	var unlisted_consumable := PickupConfig.new()
	unlisted_consumable.pickup_type = PickupConfig.PickupType.CONSUMABLE
	unlisted_consumable.can_store_in_inventory = true
	_expect(
		coordinator.get_sell_price(unlisted_consumable) == 0,
		"未进入 typed listing 的消耗品必须禁售。"
	)
	_expect(coordinator.get_sell_price(LOCKED_ITEM) == 0, "锁定物品必须禁售。")
	_expect(
		coordinator.get_sell_price(FLYING_ENVELOPE) == 0,
		"会飞的信封是全队唯一事件收藏品，地下商店必须禁售。"
	)
	_expect(coordinator.get_sell_price(BUILDING_ITEM) == 0, "建筑物品必须禁售。")
	_expect(coordinator.get_sell_price(UNSUPPORTED_ITEM) == 0, "未定义类型必须禁售。")
	for blocked_case in [
		{"request_id": "sell-locked", "item": LOCKED_ITEM},
		{"request_id": "sell-building", "item": BUILDING_ITEM},
	]:
		var blocked_item := blocked_case["item"] as PickupConfig
		var blocked_slot := _find_inventory_slot_for_path(
			run_state,
			1,
			blocked_item.resource_path
		)
		var blocked_inventory_revision := run_state.get_inventory_revision_for_peer(1)
		var blocked_xirang_revision := run_state.get_party_xirang_ledger_revision()
		var blocked_balance := run_state.get_party_xirang_balance(1)
		var blocked_result := coordinator.submit_sell(
			1,
			str(blocked_case["request_id"]),
			session.get_occurrence_key(),
			blocked_slot,
			blocked_item.resource_path,
			blocked_inventory_revision,
			blocked_xirang_revision,
			session.get_session_revision()
		)
		_expect(
			str(blocked_result.get("result_code", "")) == "item_not_sellable"
			and run_state.get_inventory_revision_for_peer(1)
			== blocked_inventory_revision
			and run_state.get_party_xirang_ledger_revision()
			== blocked_xirang_revision
			and run_state.get_party_xirang_balance(1) == blocked_balance,
			"锁定与建筑物品的禁售请求不得产生部分写入。"
		)
	var page_zero := coordinator.get_sell_inventory_page(1, 0)
	_expect(
		(page_zero.get("slots", []) as Array).size() == 8,
		"出售页必须固定为 4×2 的 8 个背包原槽位。"
	)
	_expect(
		(coordinator.get_sell_inventory_page(1, 2).get("slots", []) as Array).size()
		== 8,
		"20格背包必须通过 3 个出售分页完整承载。"
	)

	var stale_balance := run_state.get_party_xirang_balance(1)
	var stale_inventory := run_state.export_inventory_snapshot_for_peer(1)
	var stale_sell := coordinator.submit_sell(
		1,
		"stale-sell",
		session.get_occurrence_key(),
		potion_slot,
		HEALTH_POTION.resource_path,
		run_state.get_inventory_revision_for_peer(1) - 1,
		run_state.get_party_xirang_ledger_revision()
	)
	_expect(not bool(stale_sell.get("success", true)), "过期出售请求必须拒绝。")
	_expect(
		run_state.get_party_xirang_balance(1) == stale_balance
		and run_state.export_inventory_snapshot_for_peer(1) == stale_inventory,
		"过期请求不得产生任一侧的部分写入。"
	)

	_expect(run_state.set_party_xirang_balance(2, 0), "余额不足测试必须清空玩家2息壤。")
	var insufficient_inventory := run_state.export_inventory_snapshot_for_peer(2)
	var insufficient_shelf := session.get_shelf_revision(2)
	var insufficient := coordinator.submit_purchase(
		2,
		"insufficient-purchase",
		session.get_occurrence_key(),
		0,
		insufficient_shelf,
		run_state.get_inventory_revision_for_peer(2),
		run_state.get_party_xirang_ledger_revision(),
		session.get_session_revision()
	)
	_expect(
		str(insufficient.get("result_code", "")) == "insufficient_xirang",
		"个人息壤不足必须明确拒绝。"
	)
	_expect(
		run_state.get_party_xirang_balance(2) == 0
		and run_state.export_inventory_snapshot_for_peer(2) == insufficient_inventory
		and session.get_shelf_revision(2) == insufficient_shelf,
		"余额不足不得写入背包或售罄状态。"
	)
	_expect(run_state.set_party_xirang_balance(2, 20000), "满背包测试必须恢复玩家2余额。")
	var stale_session_inventory := run_state.export_inventory_snapshot_for_peer(2)
	var stale_session_balance := run_state.get_party_xirang_balance(2)
	var stale_session_purchase := coordinator.submit_purchase(
		2,
		"stale-session-purchase",
		session.get_occurrence_key(),
		0,
		session.get_shelf_revision(2),
		run_state.get_inventory_revision_for_peer(2),
		run_state.get_party_xirang_ledger_revision(),
		session.get_session_revision() - 1
	)
	_expect(
		str(stale_session_purchase.get("result_code", "")) == "stale_state",
		"过期 session revision 的购买必须拒绝。"
	)
	_expect(
		run_state.get_party_xirang_balance(2) == stale_session_balance
		and run_state.export_inventory_snapshot_for_peer(2) == stale_session_inventory
		and session.get_shelf_revision(2) == insufficient_shelf,
		"过期 session 请求不得产生部分写入。"
	)

	# Fill player 2 with twenty non-stackable collectibles; any offer then has
	# no destination slot, including a consumable which has no existing stack.
	var full_pool := CollectibleRegistry.get_standard_random_pool()
	for pool_index in RunStateStore.INVENTORY_CAPACITY:
		_expect(
			run_state.try_add_item_for_peer(2, full_pool[pool_index]),
			"满背包测试必须填满 20 个非叠加收藏品。"
		)
	var full_balance := run_state.get_party_xirang_balance(2)
	var full_snapshot := run_state.export_inventory_snapshot_for_peer(2)
	var full_purchase := coordinator.submit_purchase(
		2,
		"full-purchase",
		session.get_occurrence_key(),
		0,
		session.get_shelf_revision(2),
		run_state.get_inventory_revision_for_peer(2),
		run_state.get_party_xirang_ledger_revision()
	)
	_expect(
		str(full_purchase.get("result_code", "")) == "inventory_full",
		"满背包购买必须明确拒绝。"
	)
	_expect(
		run_state.get_party_xirang_balance(2) == full_balance
		and run_state.export_inventory_snapshot_for_peer(2) == full_snapshot
		and not bool(session.get_offer(2, 0).get("purchased", false)),
		"满背包购买不得扣款或写入售罄状态。"
	)

	coordinator.queue_free()
	run_state.queue_free()


func _count_collectible_offers(offers: Array[Dictionary]) -> int:
	var result := 0
	for offer in offers:
		if str(offer.get("kind", "")) == "collectible":
			result += 1
	return result


func _find_available_offer_by_kind(
	session: RogueUndergroundShopSession,
	peer_id: int,
	kind: String
) -> int:
	for offer_index in RogueUndergroundShopSession.OFFER_COUNT:
		var offer := session.get_offer(peer_id, offer_index)
		if (
			str(offer.get("kind", "")) == kind
			and not bool(offer.get("purchased", false))
		):
			return offer_index
	return -1


func _get_expected_consumable_prices() -> Dictionary:
	return {
		HEALTH_POTION.resource_path: 50,
		LARGE_HEALING_POTION.resource_path: 200,
		ROCK_POTION.resource_path: 70,
		LARGE_ROCK_POTION.resource_path: 280,
	}


func _get_empty_consumable_counts() -> Dictionary:
	var result: Dictionary = {}
	for config_path in _get_expected_consumable_prices():
		result[config_path] = 0
	return result


func _find_inventory_slot_for_path(
	run_state: RunStateStore,
	peer_id: int,
	config_path: String
) -> int:
	for slot_index in RunStateStore.INVENTORY_CAPACITY:
		if str(run_state.get_inventory_slot_state_for_peer(
			peer_id,
			slot_index
		).get("config_path", "")) == config_path:
			return slot_index
	return -1


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_UNDERGROUND_SHOP_DOMAIN_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
