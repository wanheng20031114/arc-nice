extends SceneTree

const BASKETBALL: PickupConfig = preload(
	"res://resources/config/collectibles/collectible_basketball.tres"
)
const BASKETBALL_PATH := (
	"res://resources/config/collectibles/collectible_basketball.tres"
)
const SPECIAL_COLOR := Color("7EE3C4")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_enum_and_helpers()
	_test_basketball_config()
	_test_registry_pool_split()
	_test_codex_semantics()
	_test_generic_card_palette()
	if failures.is_empty():
		print("SPECIAL_COLLECTIBLE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_enum_and_helpers() -> void:
	_expect(
		PickupConfig.CollectibleRarity.COMMON == 0
		and PickupConfig.CollectibleRarity.RARE == 1
		and PickupConfig.CollectibleRarity.EPIC == 2
		and PickupConfig.CollectibleRarity.LEGENDARY == 3
		and PickupConfig.CollectibleRarity.SPECIAL == 4,
		"Special must append to the rarity/category enum without renumbering 0..3."
	)
	_expect(
		PickupConfig.get_collectible_rarity_label(
			PickupConfig.CollectibleRarity.SPECIAL
		) == "特殊"
		and PickupConfig.get_collectible_classification_stat_label(
			PickupConfig.CollectibleRarity.SPECIAL
		) == "分类"
		and PickupConfig.get_collectible_classification_stat_label(
			PickupConfig.CollectibleRarity.LEGENDARY
		) == "稀有度"
		and PickupConfig.get_collectible_rarity_bbcode_color(
			PickupConfig.CollectibleRarity.SPECIAL
		) == "#7EE3C4",
		"Special helpers must expose category wording and the cyan accent."
	)


func _test_basketball_config() -> void:
	_expect(BASKETBALL != null, "Basketball config must load.")
	if BASKETBALL == null:
		return
	_expect(
		BASKETBALL.resource_path == BASKETBALL_PATH
		and BASKETBALL.pickup_type == PickupConfig.PickupType.COLLECTIBLE
		and BASKETBALL.display_name == "篮球"
		and BASKETBALL.description == "会在某个特殊节点发挥作用。"
		and BASKETBALL.can_store_in_inventory
		and not BASKETBALL.stackable
		and not BASKETBALL.inventory_locked
		and BASKETBALL.collectible_effect_id
		== PickupConfig.COLLECTIBLE_EFFECT_BASKETBALL
		and BASKETBALL.collectible_design_id == "basketball"
		and BASKETBALL.collectible_rarity
		== PickupConfig.CollectibleRarity.SPECIAL,
		"Basketball must remain an unlocked, non-stackable, event-only special collectible."
	)
	_expect(
		BASKETBALL.icon_texture != null,
		"Basketball must reference its imported collectible icon."
	)


func _test_registry_pool_split() -> void:
	var all_items := CollectibleRegistry.get_all()
	var standard_items := CollectibleRegistry.get_standard_random_pool()
	_expect(
		all_items.size() == 124
		and standard_items.size() == 123
		and all_items.has(BASKETBALL)
		and not standard_items.has(BASKETBALL),
		"The complete registry must include basketball while the standard random pool excludes it."
	)
	for item in standard_items:
		_expect(
			CollectibleRegistry.is_standard_random_collectible(item)
			and item.collectible_rarity
			<= PickupConfig.CollectibleRarity.LEGENDARY,
			"Every standard random entry must belong to ordinary rarity 0..3."
		)
	_expect(
		LuoxiMerchant.get_collectible_pool() == standard_items,
		"Luoxi and callers shared with Xiaocong must use the standard random pool."
	)


func _test_codex_semantics() -> void:
	var basketball_entry: CodexEntryViewData
	for entry in CodexCatalog.new().get_entries(CodexSection.COLLECTIBLE):
		if entry.entry_id == &"basketball":
			basketball_entry = entry
			break
	_expect(basketball_entry != null, "The codex must include basketball.")
	if basketball_entry == null:
		return
	_expect(
		basketball_entry.primary_badge == "特殊"
		and basketball_entry.filter_key == &"special"
		and basketball_entry.filter_label == "特殊"
		and basketball_entry.accent_color.is_equal_approx(SPECIAL_COLOR)
		and basketball_entry.stats.size() == 1
		and basketball_entry.stats[0].label == "分类"
		and basketball_entry.stats[0].value == "特殊"
		and basketball_entry.notes == PackedStringArray([
			"当前战斗效果：无",
			"获取方式：事件限定",
			"持有规则：可重复获得，每份独立占用一个背包或仓库槽位",
		]),
		"The codex must present special as a category, never as a fifth rarity tier."
	)


func _test_generic_card_palette() -> void:
	var special := PickupConfig.CollectibleRarity.SPECIAL
	_expect(
		LuoxiCollectibleChoiceOverlay.get_card_rarity_color(special).is_equal_approx(
			SPECIAL_COLOR
		)
		and LuoxiCollectibleChoiceOverlay.get_card_aura_strength(special)
		< LuoxiCollectibleChoiceOverlay.get_card_aura_strength(
			PickupConfig.CollectibleRarity.LEGENDARY
		),
		"Generic collectible cards must use cyan for special without treating it as above legendary."
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
