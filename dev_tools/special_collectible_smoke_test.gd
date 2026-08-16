extends SceneTree

const BASKETBALL: PickupConfig = preload(
	"res://resources/config/collectibles/collectible_basketball.tres"
)
const BASKETBALL_PATH := (
	"res://resources/config/collectibles/collectible_basketball.tres"
)
const FLYING_ENVELOPE: PickupConfig = preload(
	"res://resources/config/collectibles/collectible_flying_envelope.tres"
)
const FLYING_ENVELOPE_PATH := (
	"res://resources/config/collectibles/collectible_flying_envelope.tres"
)
const SPECIAL_COLOR := Color("7EE3C4")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_enum_and_helpers()
	_test_basketball_config()
	_test_flying_envelope_config()
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


func _test_flying_envelope_config() -> void:
	_expect(FLYING_ENVELOPE != null, "Flying envelope config must load.")
	if FLYING_ENVELOPE == null:
		return
	_expect(
		FLYING_ENVELOPE.resource_path == FLYING_ENVELOPE_PATH
		and FLYING_ENVELOPE.pickup_type == PickupConfig.PickupType.COLLECTIBLE
		and FLYING_ENVELOPE.display_name == "会飞的信封"
		and FLYING_ENVELOPE.can_store_in_inventory
		and not FLYING_ENVELOPE.stackable
		and not FLYING_ENVELOPE.inventory_locked
		and FLYING_ENVELOPE.collectible_effect_id
		== PickupConfig.COLLECTIBLE_EFFECT_FLYING_ENVELOPE
		and FLYING_ENVELOPE.collectible_design_id == "flying_envelope"
		and FLYING_ENVELOPE.collectible_rarity
		== PickupConfig.CollectibleRarity.SPECIAL,
		"Flying envelope must be an unlocked, non-stackable, event-only special collectible."
	)
	_expect(
		FLYING_ENVELOPE.icon_texture != null,
		"Flying envelope must reference its imported 32x32 icon."
	)


func _test_registry_pool_split() -> void:
	var all_items := CollectibleRegistry.get_all()
	var standard_items := CollectibleRegistry.get_standard_random_pool()
	_expect(
		all_items.size() == 125
		and standard_items.size() == 123
		and all_items.has(BASKETBALL)
		and all_items.has(FLYING_ENVELOPE)
		and not standard_items.has(BASKETBALL),
		"The complete registry must include both specials while the standard random pool excludes them."
	)
	_expect(
		not standard_items.has(FLYING_ENVELOPE),
		"The flying envelope must never enter ordinary collectible rolls."
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
	var basketball_id := StringName(
		RuntimeContentCatalog.get_pickup_id_for_path(BASKETBALL_PATH)
	)
	var flying_envelope_id := StringName(
		RuntimeContentCatalog.get_pickup_id_for_path(FLYING_ENVELOPE_PATH)
	)
	var basketball_entry: CodexEntryViewData
	var flying_envelope_entry: CodexEntryViewData
	for entry in CodexCatalog.new().get_entries(CodexSection.COLLECTIBLE):
		if entry.entry_id == basketball_id:
			basketball_entry = entry
		elif entry.entry_id == flying_envelope_id:
			flying_envelope_entry = entry
	_expect(
		basketball_id != &"" and flying_envelope_id != &"",
		"Special collectible codex entries must reuse stable runtime IDs."
	)
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
	_expect(flying_envelope_entry != null, "The codex must include the flying envelope.")
	if flying_envelope_entry == null:
		return
	_expect(
		flying_envelope_entry.primary_badge == "特殊"
		and flying_envelope_entry.notes == PackedStringArray([
			"当前战斗效果：无",
			"获取方式：事件限定",
			"持有规则：全队本局限一份，可放入背包或共享仓库",
			"出售规则：地下商店不回收",
		]),
		"The flying-envelope codex notes must expose its party-unique, non-sellable rules."
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
