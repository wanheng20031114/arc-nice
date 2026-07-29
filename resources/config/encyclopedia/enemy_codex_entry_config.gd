extends Resource
class_name EnemyCodexEntryConfig

enum Rank {
	NORMAL,
	ELITE,
	BOSS,
}

@export_group("标识")
@export var entry_id: StringName
@export var enemy_config: EnemyConfig
@export var boss_config: BossConfig
@export var family_id: StringName
@export var family_label: String
@export var rank: Rank = Rank.NORMAL
@export var sort_order: int = 0
@export var visible_in_codex: bool = true

@export_group("玩家信息")
@export_multiline var description: String
@export var traits: PackedStringArray = PackedStringArray()

@export_group("预览")
@export var preview_frames: SpriteFrames
@export var preview_animation: StringName = &"move"
@export var preview_scale: Vector2 = Vector2.ONE
@export var preview_offset: Vector2 = Vector2.ZERO


func get_icon() -> Texture2D:
	if (
		preview_frames == null
		or preview_animation.is_empty()
		or not preview_frames.has_animation(preview_animation)
		or preview_frames.get_frame_count(preview_animation) <= 0
	):
		return null
	return preview_frames.get_frame_texture(preview_animation, 0)


func is_valid() -> bool:
	if (
		entry_id.is_empty()
		or enemy_config == null
		or enemy_config.display_name.strip_edges().is_empty()
		or family_id.is_empty()
		or family_label.strip_edges().is_empty()
		or description.strip_edges().is_empty()
		or traits.is_empty()
		or preview_frames == null
		or preview_animation.is_empty()
		or not preview_frames.has_animation(preview_animation)
		or preview_frames.get_frame_count(preview_animation) <= 0
		or preview_scale.x <= 0.0
		or preview_scale.y <= 0.0
	):
		return false
	if rank < Rank.NORMAL or rank > Rank.BOSS:
		return false
	if rank == Rank.BOSS:
		return boss_config != null and boss_config.has_required_data()
	return boss_config == null
