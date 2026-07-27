extends Resource
class_name PlantDefenseConfig

const ATTACK_SPEED_UNITS_PER_SECOND: float = 100.0
const REQUIRED_FOOTPRINT_SIZE: Vector2i = Vector2i(2, 2)

enum EnemyEngagementMode {
	PROACTIVE = 0,
	CONTACT_ONLY = 1,
}

enum BuildingCategory {
	UNSPECIFIED = 0,
	DEFENSE_TOWER = 1,
	SUPPORT_TOWER = 2,
	PRODUCTION_BUILDING = 3,
	TECHNOLOGY_BUILDING = 4,
	FENCE = 5,
	TERRAIN_BUILDING = 6,
	STORAGE_BUILDING = 7,
}

enum PlacementSurface {
	UNSPECIFIED = 0,
	GRASS_ONLY = 1,
	ANY_LAND = 2,
	WATER_ONLY = 3,
}

@export_group("基础信息")
@export var plant_id: StringName = &""
@export var display_name: String = "植物"
@export_multiline var description: String = ""
@export var icon: Texture2D
@export var plant_scene: PackedScene
@export var supports_multiplayer: bool = false

@export_group("放置预览")
@export var placement_preview_display_size := Vector2(32.0, 32.0)
@export var placement_preview_offset := Vector2.ZERO

@export_group("建筑目录")
@export var building_category: BuildingCategory = BuildingCategory.UNSPECIFIED
@export var placement_surface: PlacementSurface = PlacementSurface.UNSPECIFIED
@export_range(1, 9990, 1, "or_greater") var menu_order: int = 10

@export_group("敌人交战")
@export var enemy_engagement_mode: EnemyEngagementMode = EnemyEngagementMode.PROACTIVE
@export var cardinal_connection_group: StringName = &""

@export_group("基础数值")
@export_range(1, 9999, 1, "or_greater") var max_health: int = 100
@export_range(0, 999, 1, "or_greater") var physical_defense: int = 0
@export_range(0, 100, 1) var magic_defense: int = 0
@export_range(0, 9999, 1, "or_greater") var attack_damage: int = 0
@export_range(0.0, 99999.0, 1.0, "or_greater") var attack_speed: float = 0.0
@export_range(0.0, 2048.0, 1.0, "or_greater") var attack_range: float = 0.0
@export_range(1, 64, 1, "or_greater") var attack_burst_count: int = 1
@export_range(0.0, 10.0, 0.01, "or_greater") var attack_burst_shot_interval: float = 0.0

@export_group("占格")
@export var footprint_size: Vector2i = REQUIRED_FOOTPRINT_SIZE


func get_attack_interval() -> float:
	if attack_speed <= 0.0:
		return 0.0
	return ATTACK_SPEED_UNITS_PER_SECOND / attack_speed


func is_valid() -> bool:
	return (
		plant_id != &""
		and not display_name.is_empty()
		and icon != null
		and plant_scene != null
		and placement_preview_display_size.is_finite()
		and placement_preview_display_size.x > 0.0
		and placement_preview_display_size.y > 0.0
		and placement_preview_offset.is_finite()
		and max_health > 0
		and attack_burst_count > 0
		and is_finite(attack_burst_shot_interval)
		and attack_burst_shot_interval >= 0.0
		and (attack_burst_count == 1 or attack_burst_shot_interval > 0.0)
		and enemy_engagement_mode >= EnemyEngagementMode.PROACTIVE
		and enemy_engagement_mode <= EnemyEngagementMode.CONTACT_ONLY
		and building_category > BuildingCategory.UNSPECIFIED
		and building_category <= BuildingCategory.STORAGE_BUILDING
		and placement_surface > PlacementSurface.UNSPECIFIED
		and placement_surface <= PlacementSurface.WATER_ONLY
		and menu_order > 0
		and footprint_size.x > 0
		and footprint_size.y > 0
		and (
			cardinal_connection_group == &""
			or footprint_size == Vector2i.ONE
		)
	)


func is_proactive_enemy_target() -> bool:
	return enemy_engagement_mode == EnemyEngagementMode.PROACTIVE


func uses_cardinal_connections() -> bool:
	return cardinal_connection_group != &""


func is_water_building() -> bool:
	return placement_surface == PlacementSurface.WATER_ONLY


static func get_building_category_label(category: BuildingCategory) -> String:
	match category:
		BuildingCategory.DEFENSE_TOWER:
			return "防御塔"
		BuildingCategory.SUPPORT_TOWER:
			return "支援塔"
		BuildingCategory.PRODUCTION_BUILDING:
			return "生产建筑"
		BuildingCategory.TECHNOLOGY_BUILDING:
			return "科技建筑"
		BuildingCategory.FENCE:
			return "围栏"
		BuildingCategory.TERRAIN_BUILDING:
			return "地形建筑"
		BuildingCategory.STORAGE_BUILDING:
			return "仓储建筑"
		_:
			return "未指定"


static func get_placement_surface_label(surface: PlacementSurface) -> String:
	match surface:
		PlacementSurface.GRASS_ONLY:
			return "仅草地"
		PlacementSurface.ANY_LAND:
			return "任意陆地"
		PlacementSurface.WATER_ONLY:
			return "仅水面"
		_:
			return "未指定"
