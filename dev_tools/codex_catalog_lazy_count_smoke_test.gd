extends SceneTree

const EXPECTED_COUNTS := {
	CodexSection.ENEMY: 60,
	CodexSection.COLLECTIBLE: 125,
	CodexSection.BUILDING: 16,
}


class HideBuildingProvider:
	extends CodexVisibilityProvider


	func get_state(section: int, entry_id: StringName) -> int:
		if section == CodexSection.BUILDING and entry_id == &"simple_fence":
			return CodexVisibilityState.HIDDEN
		return CodexVisibilityState.REVEALED


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_default_counts_are_lightweight()
	_test_custom_visibility_count()
	_test_stone_golem_specific_stats()
	_test_registered_count_contracts()

	if failures.is_empty():
		print("CODEX_CATALOG_LAZY_COUNT_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_default_counts_are_lightweight() -> void:
	_expect(
		not CollectibleRegistry.is_cache_ready(),
		"Collectible cache must start cold for the lazy-count regression."
	)
	var catalog := CodexCatalog.new()
	for section_variant in CodexSection.ALL:
		var section := int(section_variant)
		var expected_count := int(EXPECTED_COUNTS[section])
		_expect(
			catalog.get_registered_count(section) == expected_count,
			"Registered %s count must be %d."
			% [CodexSection.get_label(section), expected_count]
		)
		_expect(
			catalog.get_total_count(section) == expected_count,
			"Default visible %s count must be %d."
			% [CodexSection.get_label(section), expected_count]
		)
	var cached_sections: Dictionary = catalog.get("_entries_by_section")
	_expect(
		cached_sections.is_empty(),
		"Reading default navigation counts must not materialize any section."
	)
	_expect(
		not CollectibleRegistry.is_cache_ready(),
		"Reading the collectible count must not load the 125 collectible configs."
	)


func _test_custom_visibility_count() -> void:
	var catalog := CodexCatalog.new(HideBuildingProvider.new())
	_expect(
		catalog.get_registered_count(CodexSection.BUILDING) == 16,
		"Raw registered count must remain independent of visibility."
	)
	_expect(
		catalog.get_total_count(CodexSection.BUILDING) == 15,
		"Custom visibility navigation total must exclude HIDDEN records."
	)
	var cached_sections: Dictionary = catalog.get("_entries_by_section")
	_expect(
		cached_sections.has(CodexSection.BUILDING),
		"Custom visibility total must materialize its section to preserve HIDDEN semantics."
	)
	_expect(
		catalog.get_visible_count(CodexSection.BUILDING) == 15,
		"Custom HIDDEN state must be excluded from the explicit visible count."
	)
	var entries := catalog.get_entries(CodexSection.BUILDING)
	_expect(
		entries.size() == 15 and _find_entry(entries, &"simple_fence") == null,
		"Custom HIDDEN state must match the filtered entry collection."
	)
	catalog.set_visibility_provider(null)
	cached_sections = catalog.get("_entries_by_section")
	_expect(
		cached_sections.is_empty()
		and catalog.get_total_count(CodexSection.BUILDING) == 16,
		"Restoring the default provider must clear views and restore manifest counts."
	)


func _test_stone_golem_specific_stats() -> void:
	var catalog := CodexCatalog.new()
	var entries := catalog.get_entries(CodexSection.ENEMY)
	for entry_id in [&"stone_golem", &"stone_golem_elite"]:
		var entry := _find_entry(entries, entry_id)
		_expect(entry != null, "Missing stone golem entry %s." % entry_id)
		if entry == null:
			continue
		var labels: Array[String] = []
		for row in entry.stats:
			labels.append(row.label)
		_expect(
			"砸地半径" in labels,
			"Stone golem %s must expose its ground-slam radius." % entry_id
		)
		_expect(
			"斩击角度" not in labels and "斩击外径" not in labels,
			"Stone golem %s must not use the parent knight stat branch." % entry_id
		)


func _test_registered_count_contracts() -> void:
	var catalog := CodexCatalog.new()
	for section_variant in CodexSection.ALL:
		var section := int(section_variant)
		var actual_count := catalog.get_entries(section).size()
		_expect(
			actual_count == catalog.get_registered_count(section),
			"Registered %s count drifted from its authoritative registry: %d != %d."
			% [
				CodexSection.get_label(section),
				catalog.get_registered_count(section),
				actual_count,
			]
		)


func _find_entry(
	entries: Array[CodexEntryViewData],
	entry_id: StringName
) -> CodexEntryViewData:
	for entry in entries:
		if entry.entry_id == entry_id:
			return entry
	return null


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
