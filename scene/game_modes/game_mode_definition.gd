extends Resource
class_name GameModeDefinition

## A lightweight description of one stable game mode.
##
## Scene and campaign references intentionally remain String paths. Loading the
## catalog must never pull a combat scene, campaign, texture, or audio asset into
## memory before GameLoadCoordinator starts its threaded manifest.

## 协议认识、开发入口和正式发布是三件事：目录可保留旧 wire 定义，
## 但只有 RELEASE 模式才能进入生产大厅与 Host 建房准入。
enum Visibility {
	PROTOCOL_ONLY,
	DEVELOPMENT,
	RELEASE,
}

enum SelectionAudience {
	RELEASE,
	DEVELOPMENT,
}

@export_range(0, 255, 1) var mode_id: int = 0
@export var wire_key: StringName = &""
@export var display_name: String = ""
@export var visibility: Visibility = Visibility.PROTOCOL_ONLY
@export var lobby_label: String = ""
@export_file("*.png", "*.svg", "*.webp") var lobby_icon_path: String = ""
@export_range(0, 255, 1) var lobby_order: int = 0

@export_group("Entry and runtime paths")
@export var supports_singleplayer: bool = true
@export_file("*.tscn") var singleplayer_entry_scene_path: String = ""
@export_file("*.tscn") var multiplayer_entry_scene_path: String = ""
@export_file("*.tscn") var multiplayer_runtime_scene_path: String = ""

@export_group("Campaign paths")
@export var uses_wave_campaign: bool = true
@export_file("*.tres") var singleplayer_campaign_path: String = ""
@export_file("*.tres") var multiplayer_campaign_path: String = ""

@export_group("Loading policy")
@export var include_starting_inventory: bool = true
@export var preload_profile: StringName = &""
@export_range(0.1, 32.0, 0.1) var runtime_load_weight: float = 1.0
@export_range(0.1, 32.0, 0.1) var entry_load_weight: float = 1.0


## 开发受众可进入已搭建但未发布的 fixture；PROTOCOL_ONLY 只参与解码。
func is_selectable_for(audience: SelectionAudience) -> bool:
	match audience:
		SelectionAudience.RELEASE:
			return visibility == Visibility.RELEASE
		SelectionAudience.DEVELOPMENT:
			return visibility in [Visibility.DEVELOPMENT, Visibility.RELEASE]
		_:
			return false


func validate_definition() -> PackedStringArray:
	var errors := PackedStringArray()
	if visibility not in [
		Visibility.PROTOCOL_ONLY,
		Visibility.DEVELOPMENT,
		Visibility.RELEASE,
	]:
		errors.append("mode %d has an invalid visibility" % mode_id)
	if wire_key.is_empty():
		errors.append("mode %d has an empty wire key" % mode_id)
	if visibility != Visibility.PROTOCOL_ONLY:
		if display_name.strip_edges().is_empty():
			errors.append("mode %d has an empty display name" % mode_id)
		if lobby_label.strip_edges().is_empty():
			errors.append("mode %d has an empty lobby label" % mode_id)
		if lobby_icon_path.strip_edges().is_empty():
			errors.append("mode %d has an empty lobby icon path" % mode_id)
		if supports_singleplayer and singleplayer_entry_scene_path.strip_edges().is_empty():
			errors.append("mode %d has no singleplayer entry" % mode_id)
		if multiplayer_entry_scene_path.strip_edges().is_empty():
			errors.append("mode %d has no multiplayer entry" % mode_id)
		if multiplayer_runtime_scene_path.strip_edges().is_empty():
			errors.append("mode %d has no multiplayer runtime" % mode_id)
		if uses_wave_campaign:
			if supports_singleplayer and singleplayer_campaign_path.strip_edges().is_empty():
				errors.append("mode %d has no singleplayer campaign" % mode_id)
			if multiplayer_campaign_path.strip_edges().is_empty():
				errors.append("mode %d has no multiplayer campaign" % mode_id)
	return errors
