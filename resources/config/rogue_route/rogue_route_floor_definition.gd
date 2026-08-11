@tool
extends Resource
class_name RogueRouteFloorDefinition

const RUNTIME_CONTRACT_SCHEMA := 6
const CONTENT_CONTRACT_SCHEMA := 3
const COMBAT_POOL_SCRIPT := preload(
	"res://resources/config/rogue_combat/rogue_combat_pool_config.gd"
)

@export var floor_id: StringName = &""
@export var display_name := ""
@export var generation_config: RogueRouteGenerationConfig
@export var world_metrics: RogueRouteWorldMetrics
@export var background_texture: Texture2D
@export var normal_combat_pool: COMBAT_POOL_SCRIPT
@export var special_combat_configs: Array[RogueCombatEncounterConfig] = []
@export var underground_shop_config: RogueUndergroundShopConfig


func validate_definition() -> PackedStringArray:
	var errors := PackedStringArray()
	if floor_id == &"":
		errors.append("路线楼层缺少 floor_id。")
	if display_name.strip_edges().is_empty():
		errors.append("路线楼层缺少 display_name。")
	if generation_config == null:
		errors.append("路线楼层缺少 generation_config。")
	else:
		errors.append_array(generation_config.validate_config())
	if world_metrics == null:
		errors.append("路线楼层缺少 world_metrics。")
	else:
		errors.append_array(world_metrics.validate_metrics())
	if background_texture == null:
		errors.append("路线楼层缺少 background_texture。")
	elif background_texture.get_width() <= 0 or background_texture.get_height() <= 0:
		errors.append("路线楼层背景纹理尺寸无效。")
	if normal_combat_pool == null:
		errors.append("路线楼层缺少 normal_combat_pool。")
	else:
		errors.append_array(normal_combat_pool.validate_config())
		_validate_normal_combat_pool_binding(errors)
	_validate_special_combat_configs(errors)
	if underground_shop_config == null:
		errors.append("路线楼层缺少 underground_shop_config。")
	else:
		errors.append_array(underground_shop_config.validate_config())
	if generation_config != null and world_metrics != null:
		var generation_size := Vector2i(
			generation_config.width,
			generation_config.height
		)
		if world_metrics.default_grid_size != generation_size:
			errors.append(
				"路线楼层的生成尺寸与世界默认网格尺寸不一致：%s != %s。"
				% [generation_size, world_metrics.default_grid_size]
			)
	return errors


## 权威路线快照只使用玩法契约，不读取原始图片文件，也不纳入表现标题。
func compute_runtime_contract_hash() -> String:
	if not _has_contract_inputs():
		return ""
	var generation_hash := generation_config.compute_runtime_contract_hash(
		world_metrics
	)
	var combat_hash := normal_combat_pool.compute_runtime_contract_hash()
	var special_combat_hashes := _compute_special_combat_runtime_contracts()
	var shop_hash := underground_shop_config.compute_runtime_contract_hash()
	var rare_chest_hash := RogueRareChestRegistry.compute_runtime_contract_hash()
	if (
		generation_hash.is_empty()
		or combat_hash.is_empty()
		or special_combat_hashes.size() != special_combat_configs.size()
		or shop_hash.is_empty()
		or rare_chest_hash.is_empty()
	):
		return ""
	var parts := PackedStringArray([
		"schema=%d" % RUNTIME_CONTRACT_SCHEMA,
		"floor_id=%s" % String(floor_id),
		"generation=%s" % generation_hash,
		"empty_ratio=%.6f" % generation_config.empty_ratio,
		"empty_ratio_jitter=%.6f" % generation_config.empty_ratio_jitter,
		"empty_cluster_strength=%.6f"
		% generation_config.empty_cluster_strength,
		"extra_edge_ratio=%.6f" % generation_config.extra_edge_ratio,
		"initial_action_points=%d" % generation_config.initial_action_points,
		"normal_combat_pool=%s" % combat_hash,
		"special_combat_count=%d" % special_combat_hashes.size(),
		"underground_shop=%s" % shop_hash,
		"rare_chest=%s" % rare_chest_hash,
	])
	parts.append_array(special_combat_hashes)
	return "\n".join(parts).sha256_text()


## 表现内容契约以运行契约为基线，仅补充楼层标题、背景和节点图标身份。
func compute_content_contract_hash() -> String:
	if not _has_contract_inputs():
		return ""
	var runtime_hash := compute_runtime_contract_hash()
	if runtime_hash.is_empty():
		return ""
	var parts := PackedStringArray([
		"schema=%d" % CONTENT_CONTRACT_SCHEMA,
		"runtime=%s" % runtime_hash,
		"display_name=%s" % display_name,
		"background_path=%s" % _resource_path(background_texture),
		"background_size=%d,%d" % [
			background_texture.get_width(),
			background_texture.get_height(),
		],
	])
	var type_configs := generation_config.node_type_catalog.duplicate()
	type_configs.sort_custom(func(
		first: RogueRouteNodeTypeConfig,
		second: RogueRouteNodeTypeConfig
	) -> bool:
		if first == null:
			return false
		if second == null:
			return true
		return first.node_type < second.node_type
	)
	for type_config in type_configs:
		if type_config == null:
			parts.append("node_icon=null")
		else:
			parts.append(
				"node_icon=%d:%s"
				% [type_config.node_type, _resource_path(type_config.icon)]
			)
	for config in get_sorted_normal_combat_configs():
		parts.append(_combat_content_contract("normal_combat", config))
	for config in get_sorted_special_combat_configs():
		parts.append(_combat_content_contract("special_combat", config))
	return "\n".join(parts).sha256_text()


## 统一解析当前楼层的普通作战池与特殊作战配置。
func get_combat_config(config_id: StringName) -> RogueCombatEncounterConfig:
	if config_id == &"":
		return null
	if normal_combat_pool != null:
		var normal_config := normal_combat_pool.get_combat_config(config_id)
		if normal_config != null:
			return normal_config
	return get_special_combat_config(config_id)


func get_normal_combat_config(
	config_id: StringName
) -> RogueCombatEncounterConfig:
	if normal_combat_pool == null:
		return null
	return normal_combat_pool.get_combat_config(config_id)


func select_normal_combat_config(
	node_content_seed: int
) -> RogueCombatEncounterConfig:
	if normal_combat_pool == null:
		return null
	return normal_combat_pool.select_config(node_content_seed)


func get_sorted_normal_combat_configs() -> Array[RogueCombatEncounterConfig]:
	var result: Array[RogueCombatEncounterConfig] = []
	if normal_combat_pool == null:
		return result
	for entry in normal_combat_pool.get_sorted_entries():
		if entry != null and entry.combat_config != null:
			result.append(entry.combat_config)
	return result


func get_special_combat_config(
	config_id: StringName
) -> RogueCombatEncounterConfig:
	if config_id == &"":
		return null
	for config in special_combat_configs:
		if config != null and config.encounter_id == config_id:
			return config
	return null


func get_sorted_special_combat_configs() -> Array[RogueCombatEncounterConfig]:
	var result: Array[RogueCombatEncounterConfig] = []
	for config in special_combat_configs:
		if config != null:
			result.append(config)
	result.sort_custom(_special_combat_config_less)
	return result


func _validate_special_combat_configs(errors: PackedStringArray) -> void:
	var seen_ids: Dictionary = {}
	for index in range(special_combat_configs.size()):
		var config := special_combat_configs[index]
		if config == null:
			errors.append("路线楼层特殊作战目录第%d项为空。" % (index + 1))
			continue
		errors.append_array(config.validate_config())
		var config_id := config.encounter_id
		if config_id == &"":
			continue
		if get_normal_combat_config(config_id) != null:
			errors.append(
				"路线楼层特殊作战 ID 与普通作战池重复：%s。"
				% String(config_id)
			)
		if seen_ids.has(config_id):
			errors.append(
				"路线楼层特殊作战目录包含重复 ID：%s。"
				% String(config_id)
			)
		else:
			seen_ids[config_id] = true


func _compute_special_combat_runtime_contracts() -> PackedStringArray:
	var result := PackedStringArray()
	var seen_ids: Dictionary = {}
	for config in get_sorted_special_combat_configs():
		if (
			config == null
			or not config.is_ready_to_enable()
			or config.encounter_id == &""
			or seen_ids.has(config.encounter_id)
			or get_normal_combat_config(config.encounter_id) != null
		):
			return PackedStringArray()
		var config_hash := config.compute_runtime_contract_hash()
		if config_hash.is_empty():
			return PackedStringArray()
		seen_ids[config.encounter_id] = true
		result.append(
			"special_combat=%s:%s"
			% [String(config.encounter_id), config_hash]
		)
	return result


func _validate_normal_combat_pool_binding(errors: PackedStringArray) -> void:
	if generation_config == null or normal_combat_pool == null:
		return
	var type_config := generation_config.get_type_config(
		RogueRouteGraph.NodeType.NORMAL_COMBAT
	)
	if type_config == null:
		errors.append("路线楼层缺少普通作战节点类型配置。")
	elif type_config.content_pool_id != normal_combat_pool.pool_id:
		errors.append(
			"普通作战节点内容池与楼层作战池不一致：%s != %s。" % [
				String(type_config.content_pool_id),
				String(normal_combat_pool.pool_id),
			]
		)


func _combat_content_contract(
	kind: String,
	config: RogueCombatEncounterConfig
) -> String:
	if config == null:
		return "%s=null" % kind
	return "%s=%s:%s:%s:%s" % [
		kind,
		String(config.encounter_id),
		config.event_title,
		config.objective_text,
		_texture_content_contract(config.briefing_visual),
	]


func _texture_content_contract(texture: Texture2D) -> String:
	if texture == null:
		return "null"
	if texture is AtlasTexture:
		var atlas_texture := texture as AtlasTexture
		var region := atlas_texture.region
		var margin := atlas_texture.margin
		return "atlas(%s|%.6f,%.6f,%.6f,%.6f|%.6f,%.6f,%.6f,%.6f|%d)" % [
			_resource_path(atlas_texture.atlas),
			region.position.x,
			region.position.y,
			region.size.x,
			region.size.y,
			margin.position.x,
			margin.position.y,
			margin.size.x,
			margin.size.y,
			int(atlas_texture.filter_clip),
		]
	return "texture(%s|%d,%d)" % [
		_resource_path(texture),
		texture.get_width(),
		texture.get_height(),
	]


func _special_combat_config_less(
	first: RogueCombatEncounterConfig,
	second: RogueCombatEncounterConfig
) -> bool:
	var first_id := String(first.encounter_id)
	var second_id := String(second.encounter_id)
	if first_id != second_id:
		return first_id < second_id
	return _resource_path(first) < _resource_path(second)


func _has_contract_inputs() -> bool:
	return (
		floor_id != &""
		and generation_config != null
		and world_metrics != null
		and background_texture != null
		and normal_combat_pool != null
		and underground_shop_config != null
	)


static func _resource_path(resource: Resource) -> String:
	return resource.resource_path if resource != null else ""
