extends Resource
class_name EnemyDropRule

const ContentValidationContextResource := preload(
	"res://resources/config/content_validation_context.gd"
)


@export var pickup_config: PickupConfig
@export_range(0.0, 1.0, 0.0001) var chance: float = 0.0
@export var required_tags: PackedStringArray = PackedStringArray()


func matches_tags(tags: PackedStringArray) -> bool:
	for required_tag in required_tags:
		if required_tag not in tags:
			return false
	return true


## 掉落规则按数组位置报错，不依赖运行时概率分支掩盖坏数据。
func append_validation_errors(
	context: ContentValidationContextResource,
	path: String
) -> void:
	var visit_state := context.begin_resource(self, path)
	if visit_state != ContentValidationContextResource.VisitState.ENTERED:
		return
	if pickup_config == null:
		context.add_error(
			ContentValidationContextResource.child_path(path, "pickup_config"),
			"不能为空。"
		)
	if not is_finite(chance):
		context.add_error(path, "chance 必须是有限数。")
	elif chance < 0.0 or chance > 1.0:
		context.add_error(path, "chance 必须位于 0 到 1 之间。")

	var seen_tags: Dictionary = {}
	for tag_index in range(required_tags.size()):
		var tag := required_tags[tag_index]
		var tag_path := ContentValidationContextResource.child_path(
			path,
			"required_tags[%d]" % tag_index
		)
		if tag.strip_edges().is_empty():
			context.add_error(tag_path, "不能为空。")
		elif seen_tags.has(tag):
			context.add_error(tag_path, "不能重复。")
		else:
			seen_tags[tag] = true
	context.complete_resource(self)
