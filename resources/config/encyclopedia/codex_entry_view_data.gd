extends RefCounted
class_name CodexEntryViewData

var entry_id: StringName = &""
var section: int = CodexSection.ENEMY
var display_name: String = ""
var description: String = ""
var icon: Texture2D
var preview_frames: SpriteFrames
var preview_animation: StringName = &""
var preview_scale := Vector2.ONE
var preview_offset := Vector2.ZERO
var primary_badge: String = ""
var secondary_badge: String = ""
var accent_color := Color.WHITE
var filter_key: StringName = &""
var filter_label: String = ""
var sort_group: int = 0
var sort_order: int = 0
var stats: Array[CodexStatRow] = []
var notes := PackedStringArray()
var visibility_state: int = CodexVisibilityState.REVEALED
var source_resource: Resource


func is_valid() -> bool:
	if (
		entry_id == &""
		or not CodexSection.is_valid(section)
		or display_name.is_empty()
		or not CodexVisibilityState.is_valid(visibility_state)
		or source_resource == null
	):
		return false
	for stat in stats:
		if stat == null or not stat.is_valid():
			return false
	return true
