extends SceneTree

const Rules := preload("res://scene/game_modes/tower_defense/merchants/luoxi/luoxi_special_game_rules.gd")
const Session := preload("res://scene/game_modes/tower_defense/merchants/luoxi/luoxi_special_game_session.gd")

const COMMON_COLLECTIBLE := preload(
	"res://resources/config/collectibles/collectible_apprentice_scroll.tres"
)
const RARE_COLLECTIBLE := preload(
	"res://resources/config/collectibles/collectible_alchemist_vial.tres"
)
const EPIC_COLLECTIBLE := preload(
	"res://resources/config/collectibles/collectible_apple.tres"
)
const LEGENDARY_COLLECTIBLE := preload(
	"res://resources/config/collectibles/collectible_admin_doll.tres"
)

var failures: PackedStringArray = []


func _initialize() -> void:
	_test_category_distribution()
	_test_collectible_rarity_distribution()
	_test_health_damage_distribution()
	_test_material_distribution()
	_test_core_damage_distribution()
	_test_xirang_distribution()
	_test_blank_outcome()
	_test_roll_cards_protocol()
	_test_session_reveal_and_pending_rewards()

	if failures.is_empty():
		print("GAMBLER_TICKET_RULES_SMOKE_TEST_PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_category_distribution() -> void:
	var counts: Array[int] = [0, 0, 0, 0, 0, 0]
	for roll in range(Rules.ROLL_TOTAL):
		var kind := Rules.classify_kind(roll)
		counts[kind] += 1
	_expect(
		counts == [22, 15, 22, 10, 16, 15],
		"六类结果必须精确为22/15/22/10/16/15。"
	)
	_expect(
		Rules.classify_kind(21) == Rules.OutcomeKind.COLLECTIBLE
		and Rules.classify_kind(22) == Rules.OutcomeKind.HEALTH_DAMAGE
		and Rules.classify_kind(36) == Rules.OutcomeKind.HEALTH_DAMAGE
		and Rules.classify_kind(37) == Rules.OutcomeKind.MATERIAL
		and Rules.classify_kind(58) == Rules.OutcomeKind.MATERIAL
		and Rules.classify_kind(59) == Rules.OutcomeKind.CORE_DAMAGE
		and Rules.classify_kind(68) == Rules.OutcomeKind.CORE_DAMAGE
		and Rules.classify_kind(69) == Rules.OutcomeKind.XIRANG
		and Rules.classify_kind(84) == Rules.OutcomeKind.XIRANG
		and Rules.classify_kind(85) == Rules.OutcomeKind.BLANK
		and Rules.classify_kind(99) == Rules.OutcomeKind.BLANK,
		"六类结果的整数边界必须连续且无重叠。"
	)
	_expect(
		Rules.classify_kind(-1) == Rules.INVALID_CLASSIFICATION
		and Rules.classify_kind(100) == Rules.INVALID_CLASSIFICATION,
		"主分类必须拒绝0..99以外的整数。"
	)


func _test_collectible_rarity_distribution() -> void:
	var counts: Array[int] = [0, 0, 0, 0]
	for roll in range(Rules.ROLL_TOTAL):
		counts[Rules.classify_collectible_rarity(roll)] += 1
	_expect(
		counts == [70, 20, 8, 2],
		"收藏品稀有度必须精确为70/20/8/2。"
	)
	_expect(
		Rules.classify_collectible_rarity(69)
		== PickupConfig.CollectibleRarity.COMMON
		and Rules.classify_collectible_rarity(70)
		== PickupConfig.CollectibleRarity.RARE
		and Rules.classify_collectible_rarity(89)
		== PickupConfig.CollectibleRarity.RARE
		and Rules.classify_collectible_rarity(90)
		== PickupConfig.CollectibleRarity.EPIC
		and Rules.classify_collectible_rarity(97)
		== PickupConfig.CollectibleRarity.EPIC
		and Rules.classify_collectible_rarity(98)
		== PickupConfig.CollectibleRarity.LEGENDARY,
		"收藏品稀有度的整数边界必须连续且无重叠。"
	)
	_expect(
		Rules.classify_collectible_rarity(-1) == Rules.INVALID_CLASSIFICATION
		and Rules.classify_collectible_rarity(100) == Rules.INVALID_CLASSIFICATION,
		"收藏品稀有度分类必须拒绝0..99以外的整数。"
	)


func _test_health_damage_distribution() -> void:
	var counts: Dictionary = {}
	for roll in range(Rules.ROLL_TOTAL):
		var outcome := Rules.classify_health_damage(roll)
		var key := "%d:%d" % [int(outcome["effect"]), int(outcome["amount"])]
		counts[key] = int(counts.get(key, 0)) + 1
	_expect(int(counts.get("0:40", 0)) == 30, "扣40生命的子概率必须为30%。")
	_expect(int(counts.get("0:20", 0)) == 30, "扣20生命的子概率必须为30%。")
	_expect(int(counts.get("0:10", 0)) == 10, "扣10生命的子概率必须为10%。")
	_expect(int(counts.get("1:1", 0)) == 10, "保留1生命的子概率必须为10%。")
	_expect(int(counts.get("2:90", 0)) == 5, "其他玩家扣90%生命的子概率必须为5%。")
	_expect(int(counts.get("3:1000", 0)) == 5, "全体扣1000生命的子概率必须为5%。")
	_expect(int(counts.get("0:3250", 0)) == 10, "自身扣3250生命的子概率必须为10%。")
	_expect(counts.size() == 7, "扣血分类不得产生协议外效果。")
	_expect(
		int(Rules.classify_health_damage(29)["amount"]) == 40
		and int(Rules.classify_health_damage(30)["amount"]) == 20
		and int(Rules.classify_health_damage(59)["amount"]) == 20
		and int(Rules.classify_health_damage(60)["amount"]) == 10
		and int(Rules.classify_health_damage(69)["amount"]) == 10
		and int(Rules.classify_health_damage(70)["effect"])
		== Rules.HealthEffect.SELF_LEAVE_ONE
		and int(Rules.classify_health_damage(79)["effect"])
		== Rules.HealthEffect.SELF_LEAVE_ONE
		and int(Rules.classify_health_damage(80)["effect"])
		== Rules.HealthEffect.OTHERS_CURRENT_PERCENT
		and int(Rules.classify_health_damage(84)["effect"])
		== Rules.HealthEffect.OTHERS_CURRENT_PERCENT
		and int(Rules.classify_health_damage(85)["effect"])
		== Rules.HealthEffect.ALL_FIXED
		and int(Rules.classify_health_damage(89)["effect"])
		== Rules.HealthEffect.ALL_FIXED
		and int(Rules.classify_health_damage(90)["amount"]) == 3250,
		"扣血效果的整数边界必须连续且无重叠。"
	)
	_expect(
		Rules.classify_health_damage(-1).is_empty()
		and Rules.classify_health_damage(100).is_empty(),
		"扣血分类必须拒绝0..99以外的整数。"
	)


func _test_material_distribution() -> void:
	var counts: Dictionary = {}
	var crystal_count := 0
	for roll in range(Rules.ROLL_TOTAL):
		var outcome := Rules.classify_material(roll, 0)
		var item_path := String(outcome["item_path"])
		counts[item_path] = int(counts.get(item_path, 0)) + 1
		if item_path in [Rules.WHITE_CRYSTAL_PATH, Rules.CAPOO_BLUE_CRYSTAL_PATH]:
			crystal_count += 1
	_expect(int(counts.get(Rules.DIRT_BLOCK_PATH, 0)) == 80, "土块子概率必须为80%。")
	_expect(int(counts.get(Rules.WOOD_PATH, 0)) == 5, "木头子概率必须为5%。")
	_expect(int(counts.get(Rules.SAPLING_PATH, 0)) == 5, "树苗子概率必须为5%。")
	_expect(int(counts.get(Rules.WOODEN_CORE_PATH, 0)) == 2, "木制核心子概率必须为2%。")
	_expect(crystal_count == 8, "颜色水晶子概率必须为8%。")
	_expect(
		String(Rules.classify_material(79, 0)["item_path"])
		== Rules.DIRT_BLOCK_PATH
		and String(Rules.classify_material(80, 0)["item_path"])
		== Rules.WOOD_PATH
		and String(Rules.classify_material(84, 0)["item_path"])
		== Rules.WOOD_PATH
		and String(Rules.classify_material(85, 0)["item_path"])
		== Rules.SAPLING_PATH
		and String(Rules.classify_material(89, 0)["item_path"])
		== Rules.SAPLING_PATH
		and String(Rules.classify_material(90, 0)["item_path"])
		== Rules.WOODEN_CORE_PATH
		and String(Rules.classify_material(91, 0)["item_path"])
		== Rules.WOODEN_CORE_PATH
		and String(Rules.classify_material(92, 0)["item_path"])
		== Rules.WHITE_CRYSTAL_PATH,
		"材料结果的整数边界必须连续且无重叠。"
	)
	_expect(
		String(Rules.classify_material(92, 0)["item_path"])
		== Rules.WHITE_CRYSTAL_PATH
		and String(Rules.classify_material(92, 99)["item_path"])
		== Rules.CAPOO_BLUE_CRYSTAL_PATH,
		"颜色水晶必须从白色水晶与卡普蓝晶中二选一。"
	)
	_expect(
		Rules.classify_material(-1, 0).is_empty()
		and Rules.classify_material(0, 100).is_empty(),
		"材料分类必须拒绝0..99以外的整数。"
	)


func _test_core_damage_distribution() -> void:
	var counts: Dictionary = {}
	for roll in range(Rules.ROLL_TOTAL):
		var amount := int(Rules.classify_core_damage(roll)["amount"])
		counts[amount] = int(counts.get(amount, 0)) + 1
	_expect(int(counts.get(1, 0)) == 90, "核心扣1生命的子概率必须为90%。")
	_expect(int(counts.get(5, 0)) == 10, "核心扣5生命的子概率必须为10%。")
	_expect(
		int(Rules.classify_core_damage(89)["amount"]) == 1
		and int(Rules.classify_core_damage(90)["amount"]) == 5,
		"核心扣血的整数边界必须连续且无重叠。"
	)
	_expect(
		Rules.classify_core_damage(-1).is_empty()
		and Rules.classify_core_damage(100).is_empty(),
		"核心扣血分类必须拒绝0..99以外的整数。"
	)


func _test_xirang_distribution() -> void:
	var counts: Dictionary = {}
	for roll in range(Rules.ROLL_TOTAL):
		var amount := int(Rules.classify_xirang(roll)["amount"])
		counts[amount] = int(counts.get(amount, 0)) + 1
	_expect(int(counts.get(100, 0)) == 70, "100息壤子概率必须为70%。")
	_expect(int(counts.get(325, 0)) == 20, "325息壤子概率必须为20%。")
	_expect(int(counts.get(1, 0)) == 3, "1息壤子概率必须为3%。")
	_expect(int(counts.get(799, 0)) == 3, "799息壤子概率必须为3%。")
	_expect(int(counts.get(2000, 0)) == 3, "2000息壤子概率必须为3%。")
	_expect(int(counts.get(9999, 0)) == 1, "9999息壤子概率必须为1%。")
	_expect(
		int(Rules.classify_xirang(69)["amount"]) == 100
		and int(Rules.classify_xirang(70)["amount"]) == 325
		and int(Rules.classify_xirang(89)["amount"]) == 325
		and int(Rules.classify_xirang(90)["amount"]) == 1
		and int(Rules.classify_xirang(92)["amount"]) == 1
		and int(Rules.classify_xirang(93)["amount"]) == 799
		and int(Rules.classify_xirang(95)["amount"]) == 799
		and int(Rules.classify_xirang(96)["amount"]) == 2000
		and int(Rules.classify_xirang(98)["amount"]) == 2000
		and int(Rules.classify_xirang(99)["amount"]) == 9999,
		"息壤结果的整数边界必须连续且无重叠。"
	)
	_expect(
		Rules.classify_xirang(-1).is_empty()
		and Rules.classify_xirang(100).is_empty(),
		"息壤分类必须拒绝0..99以外的整数。"
	)


func _test_blank_outcome() -> void:
	var blank := Rules.make_blank_outcome()
	_expect(
		blank == {
			"kind": Rules.OutcomeKind.BLANK,
			"effect": 0,
			"amount": 0,
			"item_path": "",
			"rarity": -1,
		}
		and Rules.is_valid_outcome(blank),
		"空白牌必须使用固定、无奖励、无代价的网络结果。"
	)
	var invalid_blank := blank.duplicate(true)
	invalid_blank["amount"] = 1
	_expect(
		not Rules.is_valid_outcome(invalid_blank),
		"空白牌不得携带任何数量或隐藏奖励。"
	)
	var session := Session.new()
	var blanks: Array[Dictionary] = [blank, blank, blank, blank]
	_expect(session.setup(11, blanks), "四张空白牌必须能建立合法会话。")
	for card_index in range(Rules.CARD_COUNT):
		session.reveal(card_index)
	_expect(
		session.get_revealed_count() == Rules.CARD_COUNT
		and session.get_pending_item_paths().is_empty()
		and session.get_pending_item_counts().is_empty()
		and session.get_pending_xirang() == 0,
		"空白牌翻开后不得进入任何延迟奖励清单。"
	)


func _test_roll_cards_protocol() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260729
	var collectible_pool: Array = [
		COMMON_COLLECTIBLE,
		RARE_COLLECTIBLE,
		EPIC_COLLECTIBLE,
		LEGENDARY_COLLECTIBLE,
	]
	var expected_collectibles: Array[PickupConfig] = [
		COMMON_COLLECTIBLE,
		RARE_COLLECTIBLE,
		EPIC_COLLECTIBLE,
		LEGENDARY_COLLECTIBLE,
	]
	for rarity in range(4):
		var collectible_outcome := Rules.roll_collectible_for_rarity(
			rng,
			collectible_pool,
			rarity
		)
		_expect(
			String(collectible_outcome.get("item_path", ""))
			== expected_collectibles[rarity].resource_path
			and int(collectible_outcome.get("rarity", -1)) == rarity,
			"收藏品必须从传入兼容池中按目标稀有度选择。"
		)
	var outcomes := Rules.roll_cards(rng, collectible_pool)
	_expect(outcomes.size() == Rules.CARD_COUNT, "规则入口必须一次生成四张牌。")
	for outcome in outcomes:
		_expect(Rules.is_valid_outcome(outcome), "每张牌必须符合固定网络协议。")
		_expect(
			outcome.keys().size() == 5
			and outcome.has("kind")
			and outcome.has("effect")
			and outcome.has("amount")
			and outcome.has("item_path")
			and outcome.has("rarity"),
			"网络结果只能由kind/effect/amount/item_path/rarity组成。"
		)


func _test_session_reveal_and_pending_rewards() -> void:
	var outcomes: Array[Dictionary] = [
		Rules.classify_material(0, 0),
		Rules.classify_material(0, 0),
		Rules.classify_xirang(0),
		Rules.classify_health_damage(0),
	]
	var session := Session.new()
	_expect(session.setup(37, outcomes), "四张合法结果必须能创建会话。")
	_expect(
		session.reveal(-1).is_empty()
		and session.reveal(Rules.CARD_COUNT).is_empty(),
		"越界翻牌必须被拒绝。"
	)
	var first_result := session.reveal(0)
	_expect(
		int(first_result.get("kind", -1)) == Rules.OutcomeKind.MATERIAL,
		"第一次翻牌必须公开该单张结果。"
	)
	_expect(session.reveal(0).is_empty(), "同一张牌不能重复翻开。")
	_expect(
		session.get_pending_item_paths() == [Rules.DIRT_BLOCK_PATH]
		and session.get_pending_item_counts() == [1],
		"首次材料结果必须进入延迟奖励。"
	)

	var public_state := session.get_public_state()
	_expect(
		public_state == {
			"revision": 37,
			"revealed_count": 1,
			"revealed_cards": [{
				"card_index": 0,
				"outcome": first_result,
			}],
		},
		"公开状态只能序列化已揭示牌，不得泄露隐藏结果。"
	)
	session.reveal(1)
	_expect(
		session.get_pending_item_paths() == [Rules.DIRT_BLOCK_PATH]
		and session.get_pending_item_counts() == [2],
		"相同物品的延迟奖励必须累计数量。"
	)
	session.reveal(2)
	_expect(session.get_pending_xirang() == 100, "息壤奖励必须延迟累计。")
	session.reveal(3)
	_expect(
		session.get_revealed_count() == Rules.CARD_COUNT,
		"四张牌必须能各自恰好翻开一次。"
	)
	_expect(
		session.get_pending_item_counts() == [2]
		and session.get_pending_xirang() == 100,
		"即时扣血结果不得进入最终发放清单。"
	)
	_expect(
		session.is_card_revealed(0)
		and session.is_card_revealed(3)
		and not session.is_card_revealed(4),
		"会话必须用范围安全的已揭示位图记录卡牌状态。"
	)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
