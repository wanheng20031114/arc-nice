extends RefCounted
class_name CollectibleRegistry

const CONFIG_DIR := "res://resources/config/collectibles"
const CONFIG_PREFIX := "collectible_"

static var _pool_cache: Array[PickupConfig] = []
static var _by_path_cache: Dictionary = {}
static var _cache_ready := false


static func get_all() -> Array[PickupConfig]:
	ensure_cache()
	return _pool_cache.duplicate()


static func get_for_path(config_path: String) -> PickupConfig:
	if config_path.is_empty():
		return null
	ensure_cache()
	return _by_path_cache.get(config_path) as PickupConfig


static func get_by_rarity(rarity: int) -> Array[PickupConfig]:
	ensure_cache()
	var result: Array[PickupConfig] = []
	for item in _pool_cache:
		if int(item.collectible_rarity) == rarity:
			result.append(item)
	return result


static func get_excluding_rarity(rarity: int) -> Array[PickupConfig]:
	ensure_cache()
	var result: Array[PickupConfig] = []
	for item in _pool_cache:
		if int(item.collectible_rarity) != rarity:
			result.append(item)
	return result


static func is_cache_ready() -> bool:
	return _cache_ready


static func get_config_paths() -> Array[String]:
	var paths: Array[String] = []
	for file_name in DirAccess.get_files_at(CONFIG_DIR):
		if file_name.get_extension() != "tres":
			continue
		if not file_name.begins_with(CONFIG_PREFIX):
			continue
		paths.append("%s/%s" % [CONFIG_DIR, file_name])
	paths.sort()
	return paths


static func cache_config(item: PickupConfig) -> void:
	if item == null or item.resource_path.is_empty():
		return
	if _by_path_cache.has(item.resource_path):
		return
	_by_path_cache[item.resource_path] = item
	_pool_cache.append(item)


static func finish_cache_warmup() -> void:
	_cache_ready = true


static func ensure_cache() -> void:
	if _cache_ready:
		return
	for config_path in get_config_paths():
		cache_config(load(config_path) as PickupConfig)
	finish_cache_warmup()


static func is_collectible_path(config_path: String) -> bool:
	return get_for_path(config_path) != null
