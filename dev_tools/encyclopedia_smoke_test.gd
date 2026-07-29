extends SceneTree

const ENCYCLOPEDIA_SCENE := preload(
	"res://scene/encyclopedia/encyclopedia_screen.tscn"
)
const ENTRY_CARD_SCENE := preload("res://scene/encyclopedia/entry_card.tscn")
const DETAIL_PANEL_SCENE := preload("res://scene/encyclopedia/detail_panel.tscn")
const BASE_VIEWPORT := Vector2i(1152, 648)
const EXPECTED_SECTION_COUNTS := {
	CodexSection.ENEMY: 29,
	CodexSection.COLLECTIBLE: 123,
	CodexSection.BUILDING: 16,
}
const EXPECTED_COLLECTIBLE_RARITY_COUNTS := {
	&"common": 41,
	&"rare": 43,
	&"epic": 26,
	&"legendary": 13,
}
const EXPECTED_BUILDING_CATEGORY_COUNTS := {
	&"defense_tower": 4,
	&"support_tower": 2,
	&"production_building": 6,
	&"technology_building": 1,
	&"fence": 1,
	&"terrain_building": 1,
	&"storage_building": 1,
}
const EXPECTED_ENEMY_FAMILY_COUNTS := {
	&"yuanshi_insect": 8,
	&"slime": 5,
	&"capoo": 8,
	&"sorcerer": 5,
	&"artificial_creation": 2,
	&"boss": 1,
}
const ATTACK_STAT_LABELS := [
	"攻击伤害",
	"攻击间隔",
	"攻击范围",
	"每轮攻击",
]


class VisibilityFixture:
	extends CodexVisibilityProvider

	var unknown_section: int
	var unknown_id: StringName
	var hidden_section: int
	var hidden_id: StringName


	func _init(
		initial_unknown_section: int,
		initial_unknown_id: StringName,
		initial_hidden_section: int,
		initial_hidden_id: StringName
	) -> void:
		unknown_section = initial_unknown_section
		unknown_id = initial_unknown_id
		hidden_section = initial_hidden_section
		hidden_id = initial_hidden_id


	func get_state(section: int, entry_id: StringName) -> int:
		if section == unknown_section and entry_id == unknown_id:
			return CodexVisibilityState.UNKNOWN
		if section == hidden_section and entry_id == hidden_id:
			return CodexVisibilityState.HIDDEN
		return CodexVisibilityState.REVEALED


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var catalog := CodexCatalog.new()
	_test_catalog_counts_and_unique_ids(catalog)
	_test_filter_counts(catalog)
	_test_entry_content(catalog)
	_test_enemy_stat_contract(catalog)
	_test_building_stat_contract(catalog)
	await _test_visibility_contract(catalog)
	await _test_scene_contract()
	catalog.clear_cache()
	catalog = null
	await _cleanup_root()

	if failures.is_empty():
		print("ENCYCLOPEDIA_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_catalog_counts_and_unique_ids(catalog: CodexCatalog) -> void:
	_expect(
		EnemyCodexRegistry.validate_contract(),
		"EnemyCodexRegistry must expose 29 valid, ordered and unique enemies."
	)
	var globally_seen_ids: Dictionary = {}
	for section_variant in CodexSection.ALL:
		var section := int(section_variant)
		var entries := catalog.get_entries(section)
		var expected_count := int(EXPECTED_SECTION_COUNTS[section])
		_expect(
			catalog.get_total_count(section) == expected_count
			and entries.size() == expected_count,
			"%s catalog must contain exactly %d entries."
			% [CodexSection.get_label(section), expected_count]
		)
		var section_seen_ids: Dictionary = {}
		for entry in entries:
			_expect(
				entry.entry_id != &"",
				"%s catalog contains an empty stable ID."
				% CodexSection.get_label(section)
			)
			_expect(
				not section_seen_ids.has(entry.entry_id),
				"%s catalog repeats stable ID %s."
				% [CodexSection.get_label(section), entry.entry_id]
			)
			section_seen_ids[entry.entry_id] = true
			_expect(
				not globally_seen_ids.has(entry.entry_id),
				"Stable ID %s is reused by multiple codex sections."
				% entry.entry_id
			)
			globally_seen_ids[entry.entry_id] = section


func _test_filter_counts(catalog: CodexCatalog) -> void:
	_expect_filter_counts(
		catalog,
		CodexSection.COLLECTIBLE,
		EXPECTED_COLLECTIBLE_RARITY_COUNTS,
		"Collectible rarity"
	)
	_expect_filter_counts(
		catalog,
		CodexSection.BUILDING,
		EXPECTED_BUILDING_CATEGORY_COUNTS,
		"Building category"
	)
	_expect_filter_counts(
		catalog,
		CodexSection.ENEMY,
		EXPECTED_ENEMY_FAMILY_COUNTS,
		"Enemy family"
	)


func _expect_filter_counts(
	catalog: CodexCatalog,
	section: int,
	expected_counts: Dictionary,
	contract_name: String
) -> void:
	var actual_counts: Dictionary = {}
	for entry in catalog.get_entries(section):
		actual_counts[entry.filter_key] = (
			int(actual_counts.get(entry.filter_key, 0)) + 1
		)
	_expect(
		actual_counts == expected_counts,
		"%s counts are incorrect: %s." % [contract_name, actual_counts]
	)
	var option_counts: Dictionary = {}
	for option in catalog.get_filter_options(section):
		option_counts[StringName(option["key"])] = int(option["count"])
	_expect(
		option_counts == expected_counts,
		"%s filter options must match the catalog entries: %s."
		% [contract_name, option_counts]
	)


func _test_entry_content(catalog: CodexCatalog) -> void:
	for section_variant in CodexSection.ALL:
		var section := int(section_variant)
		for entry in catalog.get_entries(section):
			var entry_context := "%s/%s" % [
				CodexSection.get_key(section),
				entry.entry_id,
			]
			_expect(entry.is_valid(), "%s must be valid view data." % entry_context)
			_expect(
				entry.visibility_state == CodexVisibilityState.REVEALED,
				"Default visibility must reveal %s." % entry_context
			)
			_expect(
				not entry.display_name.strip_edges().is_empty(),
				"%s must have a player-facing name." % entry_context
			)
			_expect(
				not entry.description.strip_edges().is_empty(),
				"%s must have a player-facing description." % entry_context
			)
			_expect(
				entry.icon != null,
				"%s must have a catalog image." % entry_context
			)
			if section == CodexSection.ENEMY:
				_expect(
					entry.preview_frames != null
					and entry.preview_frames.has_animation(entry.preview_animation)
					and entry.preview_frames.get_frame_count(entry.preview_animation) > 0,
					"%s must have a valid detail preview animation."
					% entry_context
				)
			elif section == CodexSection.COLLECTIBLE:
				var item := entry.source_resource as PickupConfig
				_expect(
					item != null and entry.description == item.description,
					"%s must use the collectible's public effect description."
					% entry_context
				)
				if item != null and not item.collectible_design_note.is_empty():
					_expect(
						entry.description != item.collectible_design_note,
						"%s must not expose collectible_design_note."
						% entry_context
					)


func _test_enemy_stat_contract(catalog: CodexCatalog) -> void:
	var saw_green_slime := false
	var saw_guardian := false
	var saw_linglan := false
	for entry in catalog.get_entries(CodexSection.ENEMY):
		var source := entry.source_resource as EnemyCodexEntryConfig
		_expect(source != null, "%s must retain its enemy codex source." % entry.entry_id)
		if source == null:
			continue
		var config := source.enemy_config
		var stats := _stats_to_dictionary(entry.stats)
		_expect(
			entry.stats.size() >= 7
			and _first_stat_labels(entry.stats, 7) == [
				"生命",
				"单次伤害",
				"物理防御",
				"魔法防御",
				"移动速度",
				"基地伤害",
				"击杀息壤",
			],
			"Enemy %s must begin with all seven core stat rows."
			% entry.entry_id
		)
		_expect(
			String(stats.get("生命", "")) == str(config.max_health)
			and String(stats.get("单次伤害", "")) == str(config.attack_damage)
			and String(stats.get("移动速度", "")) == _format_number(config.move_speed)
			and String(stats.get("基地伤害", "")) == str(config.home_damage)
			and String(stats.get("击杀息壤", "")) == str(config.xirang_kill_reward),
			"Enemy %s core stats must match EnemyConfig." % entry.entry_id
		)
		_expect(
			String(stats.get("物理防御", "")) == "%d 点" % config.physical_defense,
			"Enemy %s physical defense must use points." % entry.entry_id
		)
		_expect(
			String(stats.get("魔法防御", "")) == "%d%%" % config.magic_defense,
			"Enemy %s magic defense must use percent." % entry.entry_id
		)
		_expect(
			entry.preview_frames == source.preview_frames,
			"Enemy %s view data must reuse its authored SpriteFrames."
			% entry.entry_id
		)
		var scene_enemy := (
			config.enemy_scene.instantiate()
			if config.enemy_scene != null
			else null
		)
		var scene_sprite := (
			scene_enemy.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
			if scene_enemy != null
			else null
		)
		_expect(
			scene_sprite != null
			and scene_sprite.sprite_frames == entry.preview_frames,
			"Enemy %s combat scene and codex must share one SpriteFrames resource."
			% entry.entry_id
		)
		if scene_enemy != null:
			scene_enemy.free()
		if config is SlimeConfig and config.variant == SlimeConfig.Variant.GREEN:
			saw_green_slime = true
			_expect(
				String(stats.get("每次回复", ""))
				== str(GreenSlime.REGENERATION_AMOUNT)
				and String(stats.get("回复间隔", ""))
				== "%s 秒" % _format_number(
					GreenSlime.REGENERATION_INTERVAL_SECONDS
				),
				"Green slime codex stats must use its typed regeneration constants."
			)
		if config is YuanshiInsectGuardianConfig:
			saw_guardian = true
			var guardian := config as YuanshiInsectGuardianConfig
			_expect(
				String(stats.get("光环半径", ""))
				== _format_number(guardian.aura_radius)
				and String(stats.get("物防增益", ""))
				== "+%d 点" % guardian.aura_physical_defense_bonus,
				"Guardian codex stats must use its typed aura config."
			)
		if source.boss_config != null:
			saw_linglan = true
			_expect(
				stats.has("环形弹幕")
				and stats.has("追踪火箭")
				and stats.has("膨胀光球")
				and stats.has("收缩激光"),
				"Linglan must expose typed values for all four boss skills."
			)
	_expect(
		saw_green_slime and saw_guardian and saw_linglan,
		"Enemy stat contract must cover regeneration, aura and Boss adapters."
	)


func _test_building_stat_contract(catalog: CodexCatalog) -> void:
	var zero_attack_count := 0
	for entry in catalog.get_entries(CodexSection.BUILDING):
		var config := entry.source_resource as PlantDefenseConfig
		_expect(config != null, "%s must retain its building config." % entry.entry_id)
		if config == null:
			continue
		var stats := _stats_to_dictionary(entry.stats)
		_expect(
			String(stats.get("生命", "")) == str(config.max_health)
			and String(stats.get("物理防御", "")) == "%d 点" % config.physical_defense
			and String(stats.get("魔法防御", "")) == "%d%%" % config.magic_defense,
			"Building %s defenses must match PlantDefenseConfig with correct units."
			% entry.entry_id
		)
		_expect(
			entry.primary_badge
			== PlantDefenseConfig.get_building_category_label(config.building_category)
			and entry.secondary_badge
			== PlantDefenseConfig.get_placement_surface_label(config.placement_surface),
			"Building %s must expose category and terrain labels."
			% entry.entry_id
		)
		_expect(
			entry.notes.size() >= 2
			and entry.notes[0].begins_with("主要配方：")
			and entry.notes[1].begins_with("科研前置："),
			"Building %s must expose its primary recipe and research prerequisite."
			% entry.entry_id
		)
		if config.attack_damage > 0:
			continue
		zero_attack_count += 1
		for attack_label in ATTACK_STAT_LABELS:
			_expect(
				not stats.has(attack_label),
				"Zero-attack building %s must omit %s."
				% [entry.entry_id, attack_label]
			)
	_expect(
		zero_attack_count > 0,
		"Building contract must exercise at least one zero-attack building."
	)


func _test_visibility_contract(default_catalog: CodexCatalog) -> void:
	var default_enemies := default_catalog.get_entries(CodexSection.ENEMY)
	_expect(
		default_enemies.size() >= 2,
		"Visibility fixture requires at least two enemy entries."
	)
	if default_enemies.size() < 2:
		return
	var unknown_source := default_enemies[0]
	var hidden_source := default_enemies[1]
	var provider := VisibilityFixture.new(
		CodexSection.ENEMY,
		unknown_source.entry_id,
		CodexSection.ENEMY,
		hidden_source.entry_id
	)
	var catalog := CodexCatalog.new(provider)
	var entries := catalog.get_entries(CodexSection.ENEMY)
	var unknown_entry := _find_entry(entries, unknown_source.entry_id)
	var hidden_entry := _find_entry(entries, hidden_source.entry_id)
	_expect(
		entries.size() == int(EXPECTED_SECTION_COUNTS[CodexSection.ENEMY]) - 1,
		"HIDDEN must remove exactly one enemy from the catalog."
	)
	_expect(
		unknown_entry != null
		and unknown_entry.visibility_state == CodexVisibilityState.UNKNOWN,
		"UNKNOWN must remain in the catalog with its visibility state."
	)
	_expect(hidden_entry == null, "HIDDEN must be absent from catalog results.")
	if unknown_entry == null:
		return
	_expect(
		unknown_entry.display_name == unknown_source.display_name
		and unknown_entry.icon == unknown_source.icon,
		"UNKNOWN view data must retain authoritative content for the UI mask."
	)
	await _test_unknown_ui_mask(unknown_entry)


func _test_unknown_ui_mask(entry: CodexEntryViewData) -> void:
	var card := ENTRY_CARD_SCENE.instantiate() as EncyclopediaEntryCard
	root.add_child(card)
	await process_frame
	card.setup(entry)
	var icon := card.get_node("Margin/Content/ArtworkFrame/Icon") as TextureRect
	var glyph := card.get_node("Margin/Content/ArtworkFrame/UnknownGlyph") as Label
	var name := card.get_node("Margin/Content/Name") as Label
	var badge := card.get_node("Margin/Content/Badge") as Label
	var button := card.get_node("SelectButton") as Button
	_expect(
		not icon.visible and icon.texture == null and glyph.visible and glyph.text == "?",
		"UNKNOWN card must replace the real image with a question mark."
	)
	_expect(
		name.text == "未发现" and badge.text == "未知档案",
		"UNKNOWN card must hide the real name and badge."
	)
	var pressed_entries: Array[CodexEntryViewData] = []
	card.entry_pressed.connect(
		func(pressed_entry: CodexEntryViewData) -> void:
			pressed_entries.append(pressed_entry)
	)
	button.pressed.emit()
	_expect(
		pressed_entries.is_empty(),
		"UNKNOWN card must not open its detail view."
	)

	var detail := DETAIL_PANEL_SCENE.instantiate() as EncyclopediaDetailPanel
	root.add_child(detail)
	await process_frame
	detail.show_entry(entry)
	_expect(
		detail.current_entry == null,
		"Detail panel must reject UNKNOWN entries."
	)
	detail.queue_free()
	card.queue_free()
	await process_frame


func _test_scene_contract() -> void:
	root.content_scale_size = BASE_VIEWPORT
	root.size = BASE_VIEWPORT
	var screen := ENCYCLOPEDIA_SCENE.instantiate() as EncyclopediaScreen
	_expect(screen != null, "Encyclopedia scene must instantiate as EncyclopediaScreen.")
	if screen == null:
		return
	root.add_child(screen)
	current_scene = screen
	await _wait_frames(3)

	_expect(
		screen.enemy_button.text == "敌人  29"
		and screen.collectible_button.text == "收藏品  123"
		and screen.building_button.text == "建筑物  16",
		"Sidebar must display all three section totals."
	)
	_expect(
		int(screen.get("_current_section")) == CodexSection.ENEMY
		and screen.section_title.text == "敌人档案"
		and screen.archive_index.text == "029 条记录",
		"Encyclopedia must open on the enemy section."
	)
	var cards: Array = screen.get("_cards")
	_expect(
		cards.size() == 29
		and screen.entry_grid.get_child_count() == 29
		and screen.result_count.text == "显示 29 / 29",
		"Initial enemy grid must render all 29 entries."
	)
	_expect(
		screen.search_edit.text.is_empty()
		and screen.filter_button.item_count
		== EXPECTED_ENEMY_FAMILY_COUNTS.size() + 1,
		"Initial toolbar must have an empty search and all enemy family filters."
	)
	_expect(
		not screen.detail_panel.visible
		and screen.detail_panel.current_entry == null,
		"Detail inspector must start closed."
	)
	_expect(
		screen.grid_scroll.follow_focus
		and screen.enemy_button.focus_mode == Control.FOCUS_ALL,
		"Initial catalog must support keyboard and gamepad focus navigation."
	)

	await create_timer(EncyclopediaScreen.PAGE_ENTRANCE_DURATION + 0.06).timeout
	_expect(
		screen.enemy_button.has_focus(),
		"Page entrance must finish with focus on the enemy section button."
	)
	await _test_detail_layout_regression(screen, cards)
	await _test_search_filter_and_section_state(screen)
	current_scene = null
	screen.queue_free()
	await _wait_frames(3)


func _test_detail_layout_regression(
	screen: EncyclopediaScreen,
	cards: Array
) -> void:
	_expect(not cards.is_empty(), "Detail layout fixture requires at least one card.")
	if cards.is_empty():
		return
	var first_card := cards[0] as EncyclopediaEntryCard
	_expect(first_card != null, "First grid entry must be an EncyclopediaEntryCard.")
	if first_card == null:
		return
	var first_focus := first_card.get_focus_control()
	first_focus.grab_focus()
	await _wait_frames(2)
	var closed_columns := screen.entry_grid.columns
	var closed_scroll := screen.grid_scroll.scroll_vertical
	_expect(
		closed_columns > 1,
		"Closed 1152×648 grid must expose multiple columns."
	)

	first_focus.pressed.emit()
	await create_timer(
		EncyclopediaScreen.DETAIL_TRANSITION_DURATION + 0.06
	).timeout
	await _wait_frames(3)
	var open_columns := screen.entry_grid.columns
	var workspace_rect := screen.workspace.get_global_rect()
	var first_card_rect := first_card.get_global_rect()
	var detail_rect := screen.detail_panel.get_global_rect()
	_expect(
		open_columns < closed_columns,
		"Opening the 344 px inspector must reduce the responsive grid column count."
	)
	_expect(
		first_card_rect.position.x >= workspace_rect.position.x - 1.0,
		"Opening details must not push the first card left of the workspace."
	)
	_expect(
		detail_rect.position.x >= workspace_rect.position.x - 1.0
		and detail_rect.position.y >= workspace_rect.position.y - 1.0
		and detail_rect.end.x <= workspace_rect.end.x + 1.0
		and detail_rect.end.y <= workspace_rect.end.y + 1.0,
		"Detail inspector must remain fully inside the workspace at 1152×648."
	)
	_expect(
		absf(detail_rect.size.x - EncyclopediaScreen.DETAIL_WIDTH) <= 2.0,
		"Detail inspector width must remain approximately 344 px; got %.2f px."
		% detail_rect.size.x
	)

	screen.detail_panel.get_close_button().pressed.emit()
	await create_timer(
		EncyclopediaScreen.DETAIL_TRANSITION_DURATION + 0.06
	).timeout
	await _wait_frames(3)
	_expect(
		screen.entry_grid.columns == closed_columns,
		"Closing details must restore the original responsive column count."
	)
	_expect(
		screen.grid_scroll.scroll_vertical == closed_scroll,
		"Closing details must restore the prior grid scroll position."
	)
	_expect(
		first_focus.has_focus(),
		"Closing details must restore focus to the first selected card."
	)


func _test_search_filter_and_section_state(
	screen: EncyclopediaScreen
) -> void:
	_set_search_query(screen, "铃兰")
	await _wait_frames(3)
	var search_cards: Array = screen.get("_cards")
	_expect(
		not search_cards.is_empty() and search_cards.size() < 29,
		"Enemy name search must narrow the visible result set."
	)
	_expect(
		screen.result_count.text == "显示 %d / 29" % search_cards.size(),
		"Result count must stay synchronized with name-search results."
	)
	for card_variant in search_cards:
		var search_card := card_variant as EncyclopediaEntryCard
		_expect(
			search_card != null
			and search_card.entry_data.display_name.contains("铃兰"),
			"Enemy name search must only keep matching cards."
		)

	_set_search_query(screen, "")
	await _wait_frames(3)
	var enemy_filter_key := &"yuanshi_insect"
	_expect(
		_select_filter(screen, enemy_filter_key),
		"Enemy toolbar must expose the yuanshi_insect family filter."
	)
	await _wait_frames(3)
	_set_search_query(screen, "原石虫")
	await _wait_frames(3)
	var enemy_cards: Array = screen.get("_cards")
	_expect(
		not enemy_cards.is_empty()
		and _all_cards_match_filter(enemy_cards, enemy_filter_key),
		"Enemy family filtering must only retain cards from that family."
	)
	var enemy_selected_card := (
		enemy_cards[1] as EncyclopediaEntryCard
		if enemy_cards.size() > 1
		else enemy_cards[0] as EncyclopediaEntryCard
	)
	enemy_selected_card.get_focus_control().grab_focus()
	await _wait_frames(2)
	screen.call("_save_current_section_state")
	var all_states: Dictionary = screen.get("_section_states")
	var enemy_state: Dictionary = (
		all_states[CodexSection.ENEMY] as Dictionary
	).duplicate(true)
	_expect(
		String(enemy_state["query"]) == "原石虫"
		and StringName(enemy_state["filter"]) == enemy_filter_key
		and StringName(enemy_state["selected_id"])
		== enemy_selected_card.entry_data.entry_id,
		"Enemy section must record its query, filter and selected card."
	)

	await _switch_section(screen, screen.collectible_button)
	_expect(
		int(screen.get("_current_section")) == CodexSection.COLLECTIBLE,
		"Section navigation must switch from enemies to collectibles."
	)
	var collectible_filter_key := &"rare"
	_expect(
		_select_filter(screen, collectible_filter_key),
		"Collectible toolbar must expose the rare filter."
	)
	await _wait_frames(3)
	var collectible_query := "指"
	_set_search_query(screen, collectible_query)
	await _wait_frames(3)
	var collectible_cards: Array = screen.get("_cards")
	_expect(
		not collectible_cards.is_empty()
		and collectible_cards.size() < 43
		and _all_cards_match_filter(
			collectible_cards,
			collectible_filter_key
		),
		"Collectible search/filter state must remain independent of enemies."
	)
	for card_variant in collectible_cards:
		var collectible_card := card_variant as EncyclopediaEntryCard
		_expect(
			collectible_card != null
			and collectible_card.entry_data.display_name.contains(
				collectible_query
			),
			"Collectible name search must only retain matching rare cards."
		)
	var collectible_selected_card := (
		collectible_cards[collectible_cards.size() - 1]
		as EncyclopediaEntryCard
	)
	collectible_selected_card.get_focus_control().grab_focus()
	await _wait_frames(2)
	# A small explicit scroll fixture lets this state-persistence contract use a
	# meaningful name query even when its few matches fit in one natural row.
	screen.entry_grid.custom_minimum_size.y = screen.grid_scroll.size.y + 160.0
	await _wait_frames(3)
	var scroll_bar := screen.grid_scroll.get_v_scroll_bar()
	var max_scroll := maxi(
		roundi(scroll_bar.max_value - scroll_bar.page),
		0
	)
	_expect(max_scroll > 0, "Filtered collectibles must provide scrollable content.")
	if max_scroll > 0:
		screen.grid_scroll.scroll_vertical = mini(72, max_scroll)
	await process_frame
	_expect(
		screen.grid_scroll.scroll_vertical > 0,
		"Collectible section fixture must establish a non-zero scroll position."
	)
	screen.call("_save_current_section_state")
	all_states = screen.get("_section_states")
	var collectible_state: Dictionary = (
		all_states[CodexSection.COLLECTIBLE] as Dictionary
	).duplicate(true)
	_expect(
		String(collectible_state["query"]) == collectible_query
		and StringName(collectible_state["filter"])
		== collectible_filter_key
		and int(collectible_state["scroll"]) > 0
		and StringName(collectible_state["selected_id"])
		== collectible_selected_card.entry_data.entry_id,
		"Collectible section must record independent query/filter/scroll/selection."
	)

	await _switch_section(screen, screen.enemy_button)
	all_states = screen.get("_section_states")
	var restored_enemy_state: Dictionary = all_states[CodexSection.ENEMY]
	_expect(
		String(screen.search_edit.text) == String(enemy_state["query"])
		and _get_selected_filter_key(screen)
		== StringName(enemy_state["filter"])
		and screen.grid_scroll.scroll_vertical == int(enemy_state["scroll"]),
		"Returning to enemies must restore its query, filter and scroll."
	)
	_expect(
		StringName(restored_enemy_state["selected_id"])
		== StringName(enemy_state["selected_id"])
		and _cards_contain_entry_id(
			screen.get("_cards"),
			StringName(enemy_state["selected_id"])
		),
		"Returning to enemies must retain its selected entry."
	)

	await _switch_section(screen, screen.collectible_button)
	all_states = screen.get("_section_states")
	var restored_collectible_state: Dictionary = (
		all_states[CodexSection.COLLECTIBLE]
	)
	_expect(
		screen.search_edit.text == String(collectible_state["query"])
		and _get_selected_filter_key(screen)
		== StringName(collectible_state["filter"])
		and screen.grid_scroll.scroll_vertical
		== int(collectible_state["scroll"]),
		(
			"Returning to collectibles must restore query/filter/scroll; "
			+ "got query=%s filter=%s scroll=%d, expected query=%s filter=%s scroll=%d."
		)
		% [
			screen.search_edit.text,
			_get_selected_filter_key(screen),
			screen.grid_scroll.scroll_vertical,
			String(collectible_state["query"]),
			StringName(collectible_state["filter"]),
			int(collectible_state["scroll"]),
		]
	)
	_expect(
		StringName(restored_collectible_state["selected_id"])
		== StringName(collectible_state["selected_id"])
		and _cards_contain_entry_id(
			screen.get("_cards"),
			StringName(collectible_state["selected_id"])
		),
		"Returning to collectibles must retain its selected entry."
	)
	screen.entry_grid.custom_minimum_size = Vector2.ZERO


func _set_search_query(screen: EncyclopediaScreen, query: String) -> void:
	screen.search_edit.text = query
	screen.search_edit.text_changed.emit(query)


func _select_filter(screen: EncyclopediaScreen, filter_key: StringName) -> bool:
	for index in screen.filter_button.item_count:
		if StringName(screen.filter_button.get_item_metadata(index)) != filter_key:
			continue
		screen.filter_button.select(index)
		screen.filter_button.item_selected.emit(index)
		return true
	return false


func _get_selected_filter_key(screen: EncyclopediaScreen) -> StringName:
	if screen.filter_button.selected < 0:
		return &""
	return StringName(
		screen.filter_button.get_item_metadata(screen.filter_button.selected)
	)


func _all_cards_match_filter(cards: Array, filter_key: StringName) -> bool:
	for card_variant in cards:
		var card := card_variant as EncyclopediaEntryCard
		if card == null or card.entry_data.filter_key != filter_key:
			return false
	return true


func _cards_contain_entry_id(cards: Array, entry_id: StringName) -> bool:
	for card_variant in cards:
		var card := card_variant as EncyclopediaEntryCard
		if card != null and card.entry_data.entry_id == entry_id:
			return true
	return false


func _switch_section(screen: EncyclopediaScreen, button: Button) -> void:
	button.pressed.emit()
	await create_timer(
		EncyclopediaScreen.SECTION_TRANSITION_DURATION + 0.06
	).timeout
	await _wait_frames(3)


func _find_entry(
	entries: Array[CodexEntryViewData],
	entry_id: StringName
) -> CodexEntryViewData:
	for entry in entries:
		if entry.entry_id == entry_id:
			return entry
	return null


func _stats_to_dictionary(rows: Array[CodexStatRow]) -> Dictionary:
	var result: Dictionary = {}
	for row in rows:
		result[row.label] = row.value
	return result


func _first_stat_labels(rows: Array[CodexStatRow], count: int) -> Array[String]:
	var labels: Array[String] = []
	for index in mini(count, rows.size()):
		labels.append(rows[index].label)
	return labels


func _format_number(value: float) -> String:
	if is_equal_approx(value, roundf(value)):
		return str(int(roundf(value)))
	return "%.2f" % value


func _wait_frames(frame_count: int) -> void:
	for _frame in frame_count:
		await process_frame


func _cleanup_root() -> void:
	current_scene = null
	for child in root.get_children():
		if child.name in [
			&"UserSettings",
			&"RunState",
			&"NetManager",
			&"UIAudio",
			&"GameLoadCoordinator",
			&"StatusEffectExpiryScheduler",
			&"BurnStatusScheduler",
			&"BleedStatusScheduler",
			&"ColdStatusScheduler",
			&"EnemyCollectibleStatusScheduler",
		]:
			continue
		child.queue_free()
	await _wait_frames(3)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
