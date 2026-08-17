extends SceneTree

# Run from disk while a release PCK is the main pack. Mounting a PCK over the
# source project can leave editor-side class and resource caches in place.
const PACK_ARGUMENT_PREFIX := "--pack="
const EXPECTED_ENEMY_COUNT := 64
const EXPECTED_PICKUP_COUNT := 181
const EXPECTED_RECIPE_COUNT := 32
const INTERNAL_WATER_SOURCE_ID := "item.production.water_source"
const TEXT_DRIVER_SETTING := "internationalization/rendering/text_driver"
const ADVANCED_TEXT_DRIVER := "ICU / HarfBuzz / Graphite"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if not _is_running_from_declared_main_pack():
		push_error(
			"Run with --main-pack <release.pck> --script <this file> -- "
			+ "--pack=<same release.pck> so exported resources are cold-loaded."
		)
		quit(1)
		return
	_expect(
		String(ProjectSettings.get_setting(TEXT_DRIVER_SETTING, ""))
		== ADVANCED_TEXT_DRIVER,
		"Release PCK must retain the advanced text-driver selection."
	)
	_test_enemy_catalog()
	_test_pickup_catalog()
	_test_recipe_registry()
	await _cleanup_root()

	if failures.is_empty():
		print("EXPORTED_RUNTIME_CONTENT_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_enemy_catalog() -> void:
	var entries := RuntimeContentCatalog.get_enemy_entries()
	_expect(
		entries.size() == EXPECTED_ENEMY_COUNT,
		"Exported enemy trust root must contain %d entries." % EXPECTED_ENEMY_COUNT
	)
	for id_variant in entries:
		var enemy_id := str(id_variant)
		var path := str(entries[id_variant])
		var cold_resource := ResourceLoader.load(
			path,
			"",
			ResourceLoader.CACHE_MODE_IGNORE
		) as EnemyConfig
		_expect(cold_resource != null, "Exported enemy must cold-load: %s" % path)
		var loaded := RuntimeContentCatalog.load_enemy_config_from_path(path)
		_expect(
			loaded != null
			and loaded.resource_path == path
			and RuntimeContentCatalog.get_enemy_id_for_path(path) == enemy_id,
			"Exported enemy trust-root round trip must remain valid: %s" % enemy_id
		)
		cold_resource = null
		loaded = null
	entries.clear()


func _test_pickup_catalog() -> void:
	var entries := RuntimeContentCatalog.get_pickup_entries()
	_expect(
		entries.size() == EXPECTED_PICKUP_COUNT,
		"Exported pickup trust root must contain %d entries." % EXPECTED_PICKUP_COUNT
	)
	var category_counts := {
		"buildings": 0,
		"collectibles": 0,
		"consumables": 0,
		"fate": 0,
		"materials": 0,
		"pickup_triggered_items": 0,
		"production": 0,
	}
	for id_variant in entries:
		var pickup_id := str(id_variant)
		var path := str(entries[id_variant])
		var cold_resource := ResourceLoader.load(
			path,
			"",
			ResourceLoader.CACHE_MODE_IGNORE
		) as PickupConfig
		_expect(cold_resource != null, "Exported pickup must cold-load: %s" % path)
		var loaded := RuntimeContentCatalog.load_pickup_config_from_path(path)
		_expect(
			loaded != null
			and loaded.resource_path == path
			and RuntimeContentCatalog.get_pickup_id_for_path(path) == pickup_id,
			"Exported pickup trust-root round trip must remain valid: %s" % pickup_id
		)
		if loaded != null and pickup_id != INTERNAL_WATER_SOURCE_ID:
			_expect(loaded.icon_texture != null, "Public exported pickup needs an icon: %s" % pickup_id)
		var parts := pickup_id.split(".")
		if parts.size() >= 3 and category_counts.has(parts[1]):
			category_counts[parts[1]] = int(category_counts[parts[1]]) + 1
		cold_resource = null
		loaded = null
	_expect(
		category_counts == {
			"buildings": 19,
			"collectibles": 125,
			"consumables": 17,
			"fate": 1,
			"materials": 14,
			"pickup_triggered_items": 4,
			"production": 1,
		},
		"Exported pickup categories must remain closed over all 181 trusted resources."
	)


func _test_recipe_registry() -> void:
	_expect(
		ProductionRecipeRegistry.get_registered_count() == EXPECTED_RECIPE_COUNT,
		"Exported recipe registry must contain %d entries." % EXPECTED_RECIPE_COUNT
	)
	for recipe_id_variant in ProductionRecipeRegistry.RECIPE_ORDER:
		var recipe_id := StringName(recipe_id_variant)
		var path := str(ProductionRecipeRegistry.RECIPE_ID_TO_PATH.get(recipe_id, ""))
		var cold_resource := ResourceLoader.load(
			path,
			"",
			ResourceLoader.CACHE_MODE_IGNORE
		) as ProductionRecipe
		_expect(cold_resource != null, "Exported recipe must cold-load: %s" % path)
		var loaded := ProductionRecipeRegistry.get_recipe(recipe_id)
		_expect(
			loaded != null
			and loaded.resource_path == path
			and loaded.recipe_id == recipe_id
			and loaded.is_valid(),
			"Exported recipe trust-root round trip must remain valid: %s" % recipe_id
		)
		cold_resource = null
		loaded = null
	var recipes := ProductionRecipeRegistry.get_all_recipes()
	_expect(
		recipes.size() == EXPECTED_RECIPE_COUNT,
		"Exported recipe registry must cold-load all %d recipes; got %d."
		% [EXPECTED_RECIPE_COUNT, recipes.size()]
	)
	for recipe in recipes:
		_expect(recipe != null and recipe.is_valid(), "Every exported recipe must remain valid.")
	recipes.clear()


func _cleanup_root() -> void:
	current_scene = null
	for child in root.get_children():
		child.queue_free()
	for _frame in 4:
		await process_frame


func _is_running_from_declared_main_pack() -> bool:
	var pack_path := ""
	for argument_variant in OS.get_cmdline_user_args():
		var argument := str(argument_variant)
		if argument.begins_with(PACK_ARGUMENT_PREFIX):
			pack_path = argument.trim_prefix(PACK_ARGUMENT_PREFIX)
			break
	return (
		not pack_path.is_empty()
		and FileAccess.file_exists(pack_path)
		and ProjectSettings.globalize_path("res://").is_empty()
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
