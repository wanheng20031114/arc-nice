extends SceneTree

const OVERLAY_SCENE := preload("res://scene/merchants/luoxi/luoxi_collectible_choice_overlay.tscn")
const COMMON_ITEM := preload("res://resources/config/collectibles/collectible_ruby.tres")
const RARE_ITEM := preload("res://resources/config/collectibles/collectible_roller_skates.tres")
const EPIC_ITEM := preload("res://resources/config/collectibles/collectible_power_wheel.tres")
const LEGENDARY_ITEM := preload("res://resources/config/collectibles/collectible_admin_doll.tres")
const CARD_SHADER_PATH := "res://resources/shader/luoxi_collectible_card_aura.gdshader"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var overlay := OVERLAY_SCENE.instantiate() as LuoxiCollectibleChoiceOverlay
	root.add_child(overlay)
	await process_frame

	var cards := _get_cards(overlay)
	_test_quality_palette(overlay, cards)
	await _test_reveal_aura_lifecycle(overlay, cards)
	await _test_quality_visuals_follow_refreshed_slots(overlay, cards)

	overlay.free()
	await process_frame
	if failures.is_empty():
		print("LUOXI_COLLECTIBLE_RARITY_VISUAL_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_quality_palette(
	overlay: LuoxiCollectibleChoiceOverlay,
	cards: Array[PanelContainer]
) -> void:
	overlay.show_choices([COMMON_ITEM, RARE_ITEM, EPIC_ITEM], 0)
	var rarities := [
		PickupConfig.CollectibleRarity.COMMON,
		PickupConfig.CollectibleRarity.RARE,
		PickupConfig.CollectibleRarity.EPIC,
	]
	for index in range(cards.size()):
		var card := cards[index]
		var rarity: int = rarities[index]
		var style := card.get_theme_stylebox("panel") as StyleBoxFlat
		var material := card.material as ShaderMaterial
		_expect(material != null, "Every Luoxi card must use the rarity aura ShaderMaterial.")
		_expect(
			material != null
			and material.shader != null
			and material.shader.resource_path == CARD_SHADER_PATH,
			"Every Luoxi card must use the authored rarity aura shader."
		)
		_expect(
			style != null
			and _is_color_equal(
				style.border_color,
				LuoxiCollectibleChoiceOverlay.get_card_rarity_color(rarity)
			),
			"Luoxi card %d border must match its collectible rarity." % index
		)
		_expect(
			style != null
			and style.shadow_size
			== LuoxiCollectibleChoiceOverlay.get_card_shadow_size(rarity),
			"Luoxi card %d glow size must match its collectible rarity." % index
		)
		_expect(
			_is_color_equal(
				card.get_instance_shader_parameter(&"rarity_color") as Color,
				LuoxiCollectibleChoiceOverlay.get_card_rarity_color(rarity)
			),
			"Luoxi card %d must keep an independent shader rarity color." % index
		)
		_expect(
			is_equal_approx(
				float(card.get_instance_shader_parameter(&"aura_strength")),
				LuoxiCollectibleChoiceOverlay.get_card_aura_strength(rarity)
			),
			"Luoxi card %d persistent aura strength must match its rarity." % index
		)

	_expect(
		LuoxiCollectibleChoiceOverlay.get_card_shadow_size(
			PickupConfig.CollectibleRarity.EPIC
		)
		> LuoxiCollectibleChoiceOverlay.get_card_shadow_size(
			PickupConfig.CollectibleRarity.RARE
		),
		"Epic card glow must be visibly larger than rare card glow."
	)
	_expect(
		LuoxiCollectibleChoiceOverlay.get_card_aura_strength(
			PickupConfig.CollectibleRarity.EPIC
		)
		> LuoxiCollectibleChoiceOverlay.get_card_aura_strength(
			PickupConfig.CollectibleRarity.RARE
		) * 3.0,
		"Epic card shader aura must be substantially stronger than rare card aura."
	)
	overlay.hide_choices()


func _test_reveal_aura_lifecycle(
	overlay: LuoxiCollectibleChoiceOverlay,
	cards: Array[PanelContainer]
) -> void:
	overlay.show_choices([EPIC_ITEM, LEGENDARY_ITEM, COMMON_ITEM], 0)
	await create_timer(0.32).timeout
	_expect(
		float(cards[0].get_instance_shader_parameter(&"reveal_progress")) > 0.0,
		"Epic card flip must start its authored reveal aura."
	)
	_expect(
		float(cards[1].get_instance_shader_parameter(&"reveal_progress")) > 0.0,
		"Legendary card flip must start its authored reveal aura."
	)
	_expect(
		float(cards[1].get_instance_shader_parameter(&"reveal_power"))
		> float(cards[0].get_instance_shader_parameter(&"reveal_power")),
		"Legendary reveal aura must be stronger than epic reveal aura."
	)
	_expect(
		float(cards[0].get_instance_shader_parameter(&"reveal_power"))
		> LuoxiCollectibleChoiceOverlay.get_card_reveal_power(
			PickupConfig.CollectibleRarity.RARE
		) * 5.0,
		"Epic reveal aura must be substantially stronger than blue-card reveal light."
	)

	await create_timer(1.0).timeout
	for index in range(cards.size()):
		_expect(
			is_zero_approx(
				float(cards[index].get_instance_shader_parameter(&"reveal_progress"))
			),
			"Luoxi card %d reveal burst must clear after the flip." % index
		)

	overlay.show_choices([LEGENDARY_ITEM, EPIC_ITEM, RARE_ITEM], 0)
	await create_timer(0.25).timeout
	overlay.hide_choices()
	for index in range(cards.size()):
		_expect(
			is_zero_approx(
				float(cards[index].get_instance_shader_parameter(&"reveal_progress"))
			),
			"Hiding Luoxi choices must clear card %d reveal light immediately." % index
		)

	overlay.show_choices([EPIC_ITEM, LEGENDARY_ITEM, COMMON_ITEM], 0)
	overlay.hide_choices()
	await process_frame
	_expect(
		overlay.open_tween == null,
		"Hiding Luoxi choices in the opening frame must cancel the deferred flip."
	)
	for index in range(cards.size()):
		_expect(
			is_zero_approx(
				float(cards[index].get_instance_shader_parameter(&"reveal_progress"))
			),
			"A same-frame hide must not restart card %d reveal light." % index
		)


func _test_quality_visuals_follow_refreshed_slots(
	overlay: LuoxiCollectibleChoiceOverlay,
	cards: Array[PanelContainer]
) -> void:
	overlay.show_choices([COMMON_ITEM, RARE_ITEM, EPIC_ITEM], 0)
	overlay.show_choices([LEGENDARY_ITEM, COMMON_ITEM, RARE_ITEM], 0)
	var expected_rarities := [
		PickupConfig.CollectibleRarity.LEGENDARY,
		PickupConfig.CollectibleRarity.COMMON,
		PickupConfig.CollectibleRarity.RARE,
	]
	for index in range(cards.size()):
		var style := cards[index].get_theme_stylebox("panel") as StyleBoxFlat
		_expect(
			style != null
			and _is_color_equal(
				style.border_color,
				LuoxiCollectibleChoiceOverlay.get_card_rarity_color(
					expected_rarities[index]
				)
			),
			"Refreshed Luoxi card %d visuals must follow the new item rarity." % index
		)
		_expect(
			is_zero_approx(
				float(cards[index].get_instance_shader_parameter(&"reveal_progress"))
			),
			"Refreshing Luoxi cards must reset the previous slot reveal state."
		)

	await create_timer(0.65).timeout
	var base_style := cards[0].get_theme_stylebox("panel") as StyleBoxFlat
	var base_color := base_style.border_color
	overlay._on_card_mouse_entered(0)
	await create_timer(0.18).timeout
	var hover_style := cards[0].get_theme_stylebox("panel") as StyleBoxFlat
	_expect(
		hover_style.shadow_size > base_style.shadow_size,
		"Hover must strengthen the current rarity glow."
	)
	_expect(
		hover_style.border_color.is_equal_approx(base_color.lerp(Color.WHITE, 0.2)),
		"Hover must brighten the current rarity border instead of reverting to red."
	)
	overlay.hide_choices()


func _get_cards(overlay: LuoxiCollectibleChoiceOverlay) -> Array[PanelContainer]:
	var result: Array[PanelContainer] = []
	for index in range(3):
		result.append(
			overlay.get_node(
				"Root/Center/Content/CardRow/Card%d" % index
			) as PanelContainer
		)
	return result


func _is_color_equal(color_a: Color, color_b: Color) -> bool:
	return color_a.is_equal_approx(color_b)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
