extends SceneTree

const TEMPLATE_CONFIG_SCRIPT := preload(
	"res://resources/config/rogue_route/rogue_route_template_config.gd"
)
const TEMPLATE_IDS := [
	"4a", "4b", "4c", "4d", "4e", "4f", "4g", "4h", "4i", "4j",
	"5a", "5b", "5c", "5d", "5e", "5f", "5g", "5h", "5i", "5j",
]
const EXPECTED := {
	&"4a": ["6b164ba59e6baa985e7b1e48bb5efe639dd853068fba2d13e820facfabbdf853", 32, 35, 15],
	&"4b": ["bc05ee648fe358545c0dde026d4023cd263d0bc285e93b856fada8ee3c5efb14", 36, 39, 17],
	&"4c": ["7cf053ea93e6f89b236002292e30de2ae7ae5d83ac065f1e9fbb0bd1e7a83a35", 34, 37, 16],
	&"4d": ["6a5303f947386dbc422c41bfd83d9542f6ff04c18fe4e84df563eac5868cb86a", 32, 33, 17],
	&"4e": ["30000848cd2033824b3fc0e22d438984e18b5f324b976715042951cdbd74777a", 34, 37, 16],
	&"4f": ["da3f340f96754c5a55ac1d633e3def2b879a452ddd2d25cc71cf227d2f6c1244", 35, 39, 15],
	&"4g": ["4dfa36277d6583fedf8fb540fcb04e9f93e728d037a2414a8d59d09ce5765291", 36, 40, 17],
	&"4h": ["90f46a4c272c09f675796b7e6c86bed619b598a8088a9688e765b9cb00a4e41f", 32, 35, 16],
	&"4i": ["35fc53cb6d6950a24b81870cbd5704f9afef03de72eb19b33527873dcb29188e", 29, 30, 17],
	&"4j": ["1a699b1ce493e42f844ed0380cb0650346898a7592fb2f229e3ece66993cf80f", 34, 34, 15],
	&"5a": ["dc8e8a47e07a5e70e5a565b289b835b0d07c850dfa64e4c442cd6e5033a44e9b", 40, 42, 21],
	&"5b": ["a348a3d9242aad2bd2e95abe3c6071b25573b252956290633ed99d8ab2b8d51e", 40, 43, 17],
	&"5c": ["068c792a18d0a70acf1964d6dc5b4432a5dcdbb0527211bc69bb415ddad75512", 44, 46, 21],
	&"5d": ["50ce5218055e2f69840cee7f32ef2e92e6df03fd6238f800162c383b0f7c6dd4", 37, 42, 18],
	&"5e": ["70b2f598c3d489b6f81329ac55179f6932fee1159e19a3a9d5cf147c52bef7fa", 40, 43, 20],
	&"5f": ["27e7f616167ae3d33246a421486ca057d8b9e17aff03f42018c759c9280ddad3", 41, 43, 20],
	&"5g": ["48add921b1d00bffa81a044f3208fdf2a4295f0859eccd20a619cfe30f8298ab", 42, 45, 17],
	&"5h": ["0bf3978f53405818f1e67608a798672f01066f99021c89240073a9e24977e7cd", 42, 44, 21],
	&"5i": ["5b772728b9bd4ee095b2eb69a96c8a1fa80beb7811b0b10b97451536c66806b0", 39, 41, 22],
	&"5j": ["0cdb454fa0aaf614e68111aa9d3f48a66f9676d19313b492006c45f55b146461", 43, 50, 21],
}

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var seen_ids: Dictionary = {}
	for template_id_text in TEMPLATE_IDS:
		var path := (
			"res://resources/config/rogue_route/templates/%s.tres"
			% template_id_text
		)
		var template: Resource = load(path)
		_expect(template != null, "路线模板必须可加载：%s" % path)
		if template == null:
			continue
		_expect(template.get_script() == TEMPLATE_CONFIG_SCRIPT, "路线模板必须使用正式模板配置脚本：%s" % path)
		var template_id: StringName = template.get("template_id")
		_expect(not seen_ids.has(template_id), "路线模板 ID 不得重复：%s" % template_id)
		seen_ids[template_id] = true
		_expect(String(template_id) == template_id_text, "模板文件名必须与 template_id 一致：%s" % path)
		_expect(is_equal_approx(template.selection_weight, 1.0), "模板 %s 的权重必须为 1。" % template_id)
		_expect(template.width == (8 if template_id_text.begins_with("4") else 10), "模板 %s 的宽度错误。" % template_id)
		_expect(template.height == 5, "模板 %s 的高度必须为 5。" % template_id)
		var errors: PackedStringArray = template.call("validate")
		_expect(errors.is_empty(), "模板 %s 未通过结构校验：%s" % [template_id, errors])

		var expected: Array = EXPECTED[template_id]
		_expect(template.compute_topology_hash() == expected[0], "模板 %s 的拓扑哈希发生变化。" % template_id)
		_expect(template.get_node_count() == expected[1], "模板 %s 的节点数必须为 %d。" % [template_id, expected[1]])
		_expect(template.edges.size() / 2 == expected[2], "模板 %s 的边数必须为 %d。" % [template_id, expected[2]])
		var candidates: PackedInt32Array = template.call("get_valid_start_node_ids")
		_expect(candidates.size() == expected[3], "模板 %s 的合法出生候选数必须为 %d。" % [template_id, expected[3]])
		for node_id in range(template.get_node_count()):
			_expect(template.find_node_id(template.get_node_coord(node_id)) == node_id, "模板 %s 的紧凑节点 ID 与坐标必须一一对应。" % template_id)

	_expect(seen_ids.size() == TEMPLATE_IDS.size(), "必须完整加载 20 个唯一模板。")
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("ROGUE_ROUTE_TEMPLATE_CONFIG_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)
